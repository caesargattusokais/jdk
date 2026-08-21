# 02 synchronized 锁升级全链路（JDK 28）

> **快速概览**：`synchronized` 是唯一同时穿透字节码、解释器、JIT、运行时四个层面的 Java 关键字。本文按"字节码 → 解释器模板 → 解释器内联汇编 → 运行时慢路径 → 膨胀 → ObjectMonitor 排队 → 释放唤醒"逐层下钻 JDK 28 真实实现。**JDK 28 已没有偏向锁**（`UseBiasedLocking` 代码整体删除），轻量锁也从"displaced header"演进为 **LockStack（线程锁栈）** 模式，`ObjectMonitor` 结构同样大改（`_owner` 变 owner_id、`_cxq` 消失）。所有行号均为本仓库 grep 实证。
>
> 配套动画：[02-synchronized-lockupgrade-animation.html](02-synchronized-lockupgrade-animation.html)（12 步：无锁 → 轻量锁 → 自旋 → 膨胀 → EntryList 阻塞 → 释放唤醒）

---

## 目录

- [2.1 字节码层：monitorenter / monitorexit](#21-字节码层monitorenter--monitorexit)
- [2.2 解释器模板：栈帧里的 monitor block](#22-解释器模板栈帧里的-monitor-block)
- [2.3 解释器内联 fast path：fast_lock 汇编](#23-解释器内联-fast-pathfast_lock-汇编)
- [2.4 运行时慢路径：ObjectSynchronizer::enter 四段式](#24-运行时慢路径objectsynchronizerenter-四段式)
- [2.5 膨胀：inflate_and_enter（hash 先行 + monitor table）](#25-膨胀inflate_and_enterhash-先行--monitor-table)
- [2.6 ObjectMonitor 结构：JDK 28 新布局](#26-objectmonitor-结构jdk-28-新布局)
- [2.7 释放与唤醒：exit 三段式 + monitor->exit](#27-释放与唤醒exit-三段式--monitorexit)
- [2.8 JDK 28 vs 教科书：差异对照表](#28-jdk-28-vs-教科书差异对照表)
- [2.9 验证实验](#29-验证实验)

**核心文件索引**

| 文件 | 关键位置 |
|---|---|
| `src/java.base/share/classes/java/lang/Object.java` | `wait0:472`（monitor 系入口） |
| `src/hotspot/share/classfile/bytecodes.hpp` | `monitorenter=0xc2`（238 行） |
| `src/hotspot/cpu/x86/templateTable_x86.cpp` | `monitorenter:4045` / `monitorexit:4154` |
| `src/hotspot/cpu/x86/interp_masm_x86.cpp` | `lock_object:1167` / `unlock_object:1204` |
| `src/hotspot/cpu/x86/macroAssembler_x86.cpp` | `fast_lock:10589` / `fast_unlock:10654`（内联 CAS） |
| `src/hotspot/share/interpreter/interpreterRuntime.cpp` | `monitorenter:783` / `monitorexit:798`（兜底） |
| `src/hotspot/share/runtime/synchronizer.hpp/.cpp` | `enter:1725` / `exit:1785` / `inflate_fast_locked_object:1883` / `inflate_and_enter:1935` |
| `src/hotspot/share/runtime/objectMonitor.hpp/.cpp` | 结构 `hpp:172-200` / `try_enter:435` / `spin_enter:457` / `enter:484` / `exit:1401` |
| `src/hotspot/share/oops/markWord.hpp` | 锁位定义 `46-58` / 常量 `120-151` |
| `src/hotspot/share/runtime/basicLock.hpp` | `BasicLock:34` / `BasicObjectLock:70` |

---

## 2.1 字节码层：monitorenter / monitorexit

`javac` 把 `synchronized` 编译成两条字节码：

| 字节码 | 操作数 | 语义 | 定义处 |
|---|---|---|---|
| `monitorenter`（0xc2） | 栈顶对象 | 获取对象锁 | `bytecodes.hpp:238` |
| `monitorexit`（0xc3） | 栈顶对象 | 释放对象锁 | `bytecodes.hpp:239` |

```java
// 源码
synchronized (obj) { ... }
// 编译后（示意）
monitorenter obj
... 临界区 ...
monitorexit obj        // 正常路径
...（异常时由异常处理器补发 monitorexit）
```

两条细节：

1. **同步代码块的异常处理**：javac 生成的代码中，`monitorexit` 会出现在**正常出口**和**异常表 handler** 两处——方法级 `synchronized` 方法则直接在 `method_info` 里置 `ACC_SYNCHRONIZED`（0x20），由 VM 在方法进出时统一加解锁，JVM 规范规定 `monitorenter` 可重入（计数器递增）。
2. **`monitorenter` 不会阻塞死**：字节码层面它只是"尝试"入口，真正的阻塞（挂起线程）发生在解释器慢路径 / ObjectMonitor 里。

> 读到这里先停一下：`monitorenter` 的**解释器模板**才是链路真正开始的地方——下面看它在 x86 上怎么被逐条翻译成机器码。

## 2.2 解释器模板：栈帧里的 monitor block

HotSpot 解释器把每条字节码对应到一段模板机器码（`TemplateTable`）。`monitorenter` 的模板在 `templateTable_x86.cpp:4045`：

```cpp
// templateTable_x86.cpp:4045
void TemplateTable::monitorenter() {
  transition(atos, vtos);

  // check for null object
  __ null_check(rax);                                   // 4049 空指针检查

  Label is_inline_type;
  __ movptr(rbx, Address(rax, oopDesc::mark_offset_in_bytes()));
  __ test_markword_is_inline_type(rbx, is_inline_type); // 4051-4053 Valhalla：inline type 不能加锁

  // ... 在"monitor block"里找一个空闲的 Lock Record（BasicObjectLock）...
  //    4070-4098：从栈顶往下扫，找 obj 字段为 null 的槽位
  //    4103-4124：找不到就下移 rsp，扩容 monitor block

  __ movptr(Address(rmon, BasicObjectLock::obj_offset()), rax); // 4137 把对象写进 Lock Record
  __ lock_object(rmon);                                         // 4138 真正加锁（见 2.3）

  __ bind(is_inline_type);
  __ call_VM(noreg, CAST_FROM_FN_PTR(address,
                    InterpreterRuntime::throw_identity_exception), rax); // 4149 值对象抛 IdentityException
  __ should_not_reach_here();
}
```

要点：

- **monitor block 在 Java 栈帧内**：解释器帧里有专门的"锁记录区"，每个锁记录是一个 `BasicObjectLock`（`basicLock.hpp:70`），包含 `BasicLock _lock`（+ 8 字节对齐）+ `oop _obj`。模板在 4070-4098 行扫描空闲槽位，**同一对象重入时复用同一个 Lock Record**（4087-4089 行 `cmpptr rax, [rtop+obj_offset]`，对象相同就停止搜索）。
- **Valhalla 检查在最前**：`is_inline_type` 分支直接调 `throw_identity_exception`（4149）——value class 实例没有身份，**根本不允许被 synchronized**。这是 JDK 28 新增的安全网。

`monitorexit` 模板（4154 起）对称：null 检查 → 把 `_obj` 清空（释放槽位）→ `unlock_object(rmon)`。

## 2.3 解释器内联 fast path：fast_lock 汇编

`__ lock_object`（`interp_masm_x86.cpp:1167`）的真正工作在内联汇编 `MacroAssembler::fast_lock`（`macroAssembler_x86.cpp:10589`）——**这是 JDK 28 轻量锁的核心，和旧资料完全不同**：

```cpp
// macroAssembler_x86.cpp:10589
void MacroAssembler::fast_lock(Register basic_lock, Register obj, Register reg_rax, Register tmp, Label& slow) {
  ...
  movptr(reg_rax, Address(obj, oopDesc::mark_offset_in_bytes())); // 10600 预载 mark word

  // 10603 清 Lock Record 里的 monitor 缓存（防陈旧）
  movptr(Address(basic_lock, BasicObjectLock::lock_offset() +
        in_ByteSize((BasicLock::object_monitor_cache_offset_in_bytes()))), 0);

  // 10612-10616 检查线程 LockStack 是否已满
  movl(top, Address(thread, JavaThread::lock_stack_top_offset()));
  cmpl(top, LockStack::end_offset());
  jcc(Assembler::greaterEqual, slow);              // 满 → 慢路径

  // 10619-10620 递归检查：LockStack 栈顶是否就是当前对象？
  cmpptr(obj, Address(thread, top, Address::times_1, -oopSize));
  jcc(Assembler::equal, push);                     // 是 → 直接 push（重入）

  // 10623-10624 检查是否已膨胀（mark word 低 2 位 == 10）
  testptr(reg_rax, markWord::monitor_value);
  jcc(Assembler::notZero, slow);                   // monitor 已存在 → 慢路径

  // 10626-10636 无锁 → 轻量锁：CAS 把 lock 位 01 改成 00
  movptr(tmp, reg_rax);
  andptr(tmp, ~(int32_t)markWord::unlocked_value);
  orptr(reg_rax, markWord::unlocked_value);
  lock(); cmpxchgptr(tmp, Address(obj, oopDesc::mark_offset_in_bytes()));
  jcc(Assembler::notEqual, slow);                  // CAS 失败 → 慢路径

  // 10641-10645 成功：把对象 push 进线程 LockStack
  bind(push);
  movptr(Address(thread, top), obj);
  incrementl(top, oopSize);
  movl(Address(thread, JavaThread::lock_stack_top_offset()), top);
}
```

**这是 JDK 28 与教科书差异最大的一处**：

- 教科书版：CAS 把 mark word 换成**指向栈上 Lock Record 的指针**，原 mark word（displaced header）存进 Lock Record；解锁时 CAS 换回。
- **JDK 28 版：mark word 只是把锁位 `01→00`（`fast_locked`），不存任何指针**。"谁持有锁"完全由**线程私有 LockStack** 追踪——对象 push 进栈 = 已加锁，CAS 清锁位 + pop = 已解锁。省掉了 displaced header 的读写，也天然支持 O(1) 递归检测（10619 栈顶比较）。

锁位状态（`markWord.hpp:55-58`）：

```
[header          | 00]  locked     轻量锁（fast-locking in use）
[header          | 01]  unlocked   无锁
[header          | 10]  monitor    已膨胀（指向 ObjectMonitor）
[ptr             | 11]  marked     GC 标记/转发（mark word 已换出）
```

> 注意 `11` 在 JDK 28 是 **GC marked**，而旧资料里是 biased（偏向锁）——偏向锁的位被 GC 收编了。

CAS 失败或 LockStack 满时跳 `slow`，由 `lock_object` 调运行时 `InterpreterRuntime::monitorenter`（`interp_masm_x86.cpp:1185-1187`）。

## 2.4 运行时慢路径：ObjectSynchronizer::enter 四段式

`InterpreterRuntime::monitorenter`（`interpreterRuntime.cpp:783`）是解释器慢路径的入口，就干一件事：委托给 `ObjectSynchronizer::enter`（790 行）。

`enter`（`synchronizer.cpp:1725`）是整条链路的调度中枢，按顺序尝试四段：

```cpp
// synchronizer.cpp:1725
void ObjectSynchronizer::enter(Handle obj, BasicLock* lock, JavaThread* current) {
  if (obj->klass()->is_value_based()) {
    ObjectSynchronizer::handle_sync_on_value_based_class(obj, current);  // 1728-1730
  }
  CacheSetter cache_setter(current, lock);                                // 1732

  if (!lock_stack.is_full() && lock_stack.try_recursive_enter(obj())) {   // 1742 ① 递归重入
    return;
  }
  if (lock_stack.contains(obj())) {                                       // 1747 ② 已持有→递归膨胀
    ObjectMonitor* monitor = inflate_fast_locked_object(obj(), ...);
    monitor->enter(current);
    cache_setter.set_monitor(monitor);
    return;
  }
  while (true) {
    if (fast_lock_try_enter(obj(), lock_stack, current)) {                // 1761 ③ 快速加锁（自旋）
      return;
    } else if (fast_lock_spin_enter(obj(), lock_stack, current, ...)) {   // 1763 ④ 自旋等待
      return;
    }
    // deflation 竞争处理 ...
    ObjectMonitor* monitor = inflate_and_enter(obj(), lock, ...);         // 1771 最终膨胀+进入
    if (monitor != nullptr) { cache_setter.set_monitor(monitor); return; }
    observed_deflation = true;                                            // 遇到缩容→重试 fast lock
  }
}
```

四段的战术意图：

| 段 | 入口 | 行为 | 源码 |
|---|---|---|---|
| ① 递归重入 | `try_recursive_enter` | LockStack 栈顶就是 obj → 再 push 一次，O(1) | `synchronizer.cpp:1742` |
| ② 递归膨胀 | `contains` → `inflate_fast_locked_object` | 锁栈里有 obj（非栈顶，如非结构化解锁）→ 膨胀后走 monitor 递归 | `1747-1753` |
| ③ 快速加锁 | `fast_lock_try_enter` | 无锁态 CAS 抢锁 + 自旋轮次 | `1761` |
| ④ 自旋等待 | `fast_lock_spin_enter` | 短临界区自旋，避免立刻膨胀 | `1763` |
| ⑤ 膨胀兜底 | `inflate_and_enter` | 自旋无果 → 膨胀为重量级 monitor 并进入 | `1771` |

设计意图（源码注释 1755-1759）：**"Fast-lock spinning to avoid inflating for short critical sections. The goal is to only inflate when the extra cost of using ObjectMonitors is worth it."** —— 短临界区宁愿自旋，只有自旋不划算才膨胀。

## 2.5 膨胀：inflate_and_enter（hash 先行 + monitor table）

`inflate_and_enter`（`synchronizer.cpp:1935`）负责把 fast-locked 对象升级成重量级：

```cpp
// synchronizer.cpp:1935
ObjectMonitor* ObjectSynchronizer::inflate_and_enter(oop object, BasicLock* lock, ...) {
  // 1945-1950 先从线程 Lock Record 缓存读 monitor（避免重复查表）
  if (current == locking_thread) {
    monitor = read_caches(current, lock, object);
  }
  if (monitor == nullptr) {
    // 1954-1955 关键：轻量锁要求先装好 identity hash！
    // "Lightweight monitors require that hash codes are installed first"
    ObjectSynchronizer::FastHashCode(locking_thread, object);
    monitor = get_or_insert_monitor(object, current, cause);   // 1956 monitor table
  }
  if (monitor->try_enter(locking_thread)) {                     // 1959 试进
    return monitor;
  }
  // ... 1963+ deflation 竞争处理：is_being_async_deflated() → 让出/重试
  ...
}
```

三个关键机制：

1. **hash 先行**（1955）：膨胀要在 mark word 里写入指向 monitor 的指针，而 identity hash 存在 mark word 的 hash 位——**必须先调用 `FastHashCode` 把 hash 固化**，否则膨胀后 hash 会丢失。这就是 `Object.hashCode()` 在 `03-hashCode.md` 里看到的 `FastHashCode` 的另一个重要用途。
2. **monitor table**（1956）：`get_or_insert_monitor`（`synchronizer.cpp:1471`）用 **inflate lock 数组**（`inflation_lock`，273 行，按对象 hash 分段锁）保证并发膨胀只建一个 monitor；建好的 monitor 和对象的关联记录在**全局 MonitorList**。
3. **async deflation 竞争**（1963-1990）：JDK 的 `MonitorDeflation` 后台线程会回收空闲 monitor；膨胀路径必须处理"正要被缩容"的竞态——观察到 deflation 就清缓存、yield、重试。

`inflate_fast_locked_object`（1883）是另一个入口：当对象**已经被当前线程 fast-locked**（如递归、或 wait 需要 monitor 时），直接把 fast-locked mark word 换成 monitor mark，不需要竞争。

## 2.6 ObjectMonitor 结构：JDK 28 新布局

膨胀完成后，锁的权威状态移到 `ObjectMonitor`（`objectMonitor.hpp`）。**JDK 28 的字段布局与旧资料差异巨大**：

```cpp
// objectMonitor.hpp
class ObjectMonitor {
  int64_t volatile _owner;                 // 172  owner_id（int64），不再是线程指针！
                                           //     取值：owner_id / NO_OWNER / ANONYMOUS_OWNER / DEFLATER_MARKER
  volatile uint64_t _previous_owner_tid;   // 173  上一任 owner 的线程 id（锁竞争统计用）
  volatile intx _recursions;               // 181  重入计数（0 表示首次进入）
  ObjectWaiter* volatile _entry_list;      // 182  等锁队列头（旧版叫 _EntryList）
  ObjectWaiter* volatile _entry_list_tail; // 185  等锁队列尾（新增，双向链表）
  int64_t volatile _succ;                  // 186  继承者（heir presumptive），抑制无谓唤醒
  int64_t _unmounted_vthreads;             // 194  等锁队列里"未挂载虚拟线程"计数（虚拟线程专用）
  ObjectWaiter* volatile _wait_set;        // 198  wait() 等待队列（旧版叫 _WaitSet）
  volatile int _wait_set_lock;             // 200  保护 wait_set 的自旋锁
  volatile int _SpinDuration;              // 188  自适应自旋时长
};

class ObjectWaiter {                       // 43-47  队列节点
  ObjectWaiter* volatile _next, _prev;     // 双向链表
  int TState;                              // TS_RUN / TS_ENTER / TS_WAIT ...
};
```

与旧资料（JDK 8-17）的对比：

| 字段 | 旧版 | JDK 28 | 变化 |
|---|---|---|---|
| 队列头 | `_cxq`（LIFO 竞争队列）+ `_EntryList` | **只有 `_entry_list`**（带头尾指针） | `_cxq` 被合并删除 |
| owner | `void* volatile _owner`（线程指针） | `int64_t volatile _owner`（owner_id） | 存 id 不再存指针，配合 `_unmounted_vthreads` 支持虚拟线程 |
| 等待队列 | `_WaitSet` | `_wait_set` | 改名 |
| 递归 | `_recursions` | `_recursions` | 不变 |
| 继承者 | `_succ` | `_succ`（int64_t） | 类型随 owner 变化 |

**`_owner` 从指针变 id 是 JDK 21+ 虚拟线程落地的必然结果**：monitor 可能被挂起的虚拟线程持有，而"挂载线程"（carrier）会变化——存线程 id 才能稳定标识 owner。

线程进入 `_entry_list` 的完整流程在 `ObjectMonitor::enter`（`objectMonitor.cpp:484`）→ `enter_with_contention_mark`（524）→ `EnterI`（内部）：先 `spin_enter`（457，自适应自旋），失败就包成 `ObjectWaiter` 挂到 `_entry_list` 尾部，然后 `park()` 挂起，直到被 `exit` 侧的 `exit_epilog`（1519）选中唤醒。

## 2.7 释放与唤醒：exit 三段式 + monitor->exit

解锁链路与加锁对称。解释器内联 `fast_unlock`（`macroAssembler_x86.cpp:10654`）先试：LockStack 栈顶是 obj 就 pop + CAS 清锁位；不行就走 `InterpreterRuntime::monitorexit`（`interpreterRuntime.cpp:798`）→ `ObjectSynchronizer::exit`（`synchronizer.cpp:1785`）：

```cpp
// synchronizer.cpp:1785
void ObjectSynchronizer::exit(oop object, BasicLock* lock, JavaThread* current) {
  markWord mark = object->mark();

  if (mark.is_fast_locked()) {
    if (lock_stack.try_recursive_exit(object)) return;   // 1793 递归退出（LockStack pop）
    if (lock_stack.is_recursive(object)) {
      inflate_fast_locked_object(object, ...);            // 1797-1802 非结构化递归→先膨胀
    }
  }
  while (mark.is_fast_locked()) {                         // 1805-1815 普通轻量锁解锁
    markWord unlocked_mark = mark.set_unlocked();
    markWord old_mark = mark;
    mark = object->cas_set_mark(unlocked_mark, old_mark); // CAS 锁位 00→01
    if (old_mark == mark) {
      lock_stack.remove(object);                          // 从 LockStack 弹出
      return;
    }
  }

  assert(mark.has_monitor(), "must be");                  // 1817 走到这里必是 monitor
  ObjectMonitor* monitor = read_caches(current, lock, object); // 1820 先读 Lock Record 缓存
  if (monitor == nullptr) monitor = get_monitor_from_table(object); // 1822 查全局表
  monitor->exit(current);                                 // 1830 交给 ObjectMonitor
}
```

`ObjectMonitor::exit`（`objectMonitor.cpp:1401`）做重量级释放：

1. 清 `_recursions`、`_owner`（释放持有权）；
2. `exit_epilog`（1519）：从 `_entry_list` 选继承者（`_succ`）——**只唤醒一个**，避免惊群；
3. 如果 `_wait_set` 有 wait 线程且轮到它，转入 `_entry_list` 重新竞争（这是 Object 06 篇 `wait`/`notify` 的衔接点：notify 就是把 `_wait_set` 的 waiter 摘到 `_entry_list`，见 `objectMonitor.cpp:2032`）。

> 至此与 Object 系列闭环：`Object.wait()` → `wait0` → `JVM_MonitorWait` → `ObjectSynchronizer::wait` → `ObjectMonitor::wait`（`objectMonitor.cpp:1657`）——**wait 强制膨胀**（`synchronizer.cpp:545` "must use heavy weight monitor to handle wait()"），所以 `_wait_set` 只存在于膨胀后的 monitor 里。

## 2.8 JDK 28 vs 教科书：差异对照表

| # | 教科书/旧资料（JDK 8-15 时代） | JDK 28 真实实现 | 证据 |
|---|---|---|---|
| 1 | 偏向锁：锁有 `biased` 状态，mark word 存偏向线程 id | **偏向锁代码整体删除**，`11` 位是 GC marked | `UseBiasedLocking` 全仓 grep 零命中；`markWord.hpp:58` |
| 2 | 轻量锁：mark word CAS 换成指向栈上 Lock Record 的指针，displaced header 存原 mark | mark word 锁位直接 `01→00`，不存指针；Lock Record 推进线程 **LockStack** | `macroAssembler_x86.cpp:10626-10645` |
| 3 | 递归检测：遍历每帧 Lock Record / lock count | LockStack 栈顶比较 O(1) | `10619-10620`、`try_recursive_enter` |
| 4 | `_owner` 是线程指针 | `_owner` 是 **int64_t owner_id** | `objectMonitor.hpp:172` |
| 5 | `_cxq`（竞争队列）+ `_EntryList` 双队列 | **只有 `_entry_list`**（双向+tail） | `objectMonitor.hpp:182-185` |
| 6 | 膨胀 mark word 存指向 monitor 的指针，无需先装 hash | **膨胀前必须先 `FastHashCode` 固化 identity hash** | `synchronizer.cpp:1954-1955` |
| 7 | monitor 用完后可被 deflate（JDK 14+ 已有），同步 deflate | 异步 deflate（MonitorDeflation 线程），enter/exit 全路径处理竞争 | `1963-1990` |
| 8 | 无虚拟线程概念 | `_unmounted_vthreads` 计数、ObjectWaiter 支持 vthread | `objectMonitor.hpp:194` |
| 9 | synchronized 可锁任何对象 | **value class（inline type）禁止加锁**，抛 IdentityException | `templateTable_x86.cpp:4148-4151` |

**一句话总结 JDK 28 的锁模型**：`unlocked(01) → fast-locked(00, LockStack 记账) → monitor(10, ObjectMonitor 排队)`，两级跳变 + 自旋缓冲，偏向锁退场，虚拟线程与 Valhalla 全面接管。

## 2.9 验证实验

```bash
# 1. 确认 JDK 28 无偏向锁相关 flag
java -XX:+PrintFlagsFinal -version 2>&1 | grep -i biased   # 无输出 = 选项已删除

# 2. 观察解释器路径的加锁日志（需要 -Xint 强制解释执行）
java -Xint -Xlog:monitorinflation=debug -cp . LockProbe

# 3. 观察 wait 强制膨胀（衔接 Object 06）
#    -Xlog:monitorinflation=debug 时 wait() 调用会打出 inflation 事件
```

实验代码建议：两个线程竞争同一个对象的 `synchronized` 块，短临界区看自旋（不膨胀），长临界区看膨胀 + `_entry_list` 排队；用 `jcmd <pid> Thread.print` 观察 `waiting on monitor` 状态。

---

**衔接线索**：本文的 `_entry_list` 排队/唤醒细节（`EnterI` / `exit_epilog`）值得单独开一篇下钻；`FastHashCode` 与 03 篇 identity hash 复用同一函数。下一篇候选：`volatile` 的 JMM 屏障（`orderAccess.hpp:116`）。
