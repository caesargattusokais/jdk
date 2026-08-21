# 04 · `new` 关键字：TLAB 快路径与对象诞生的完整链路

> **一句话**：`new Foo()` 不是"分配内存 + 调构造器"这么简单——它是字节码 `new` → 解释器快路径（TLAB bump-pointer）→ 慢路径（三段式 MemAllocator）→ 对象头初始化 → `invokespecial <init>` 构造器调用，最后还可能被 C2 的逃逸分析整个**消灭掉**（标量替换）。
>
> **配套动画**：[04-new-tlab-animation.html](04-new-tlab-animation.html)（12 步：字节码 → TLAB 指针前移 → 慢路径 refill → 大对象 → 对象头 → 构造器）
>
> **前置**：[01 关键字全景](01-keywords-overview.md) · [02 synchronized 锁升级](02-synchronized-lockupgrade.md) · [03 volatile 内存屏障](03-volatile.md)
>
> **源码版本**：OpenJDK 28（`jdk-28+`），所有行号为当前树 grep 实证，禁止凭记忆引用。

## 快速概览

| 层级 | 发生了什么 | 源码锚点 |
|---|---|---|
| 字节码 | `new #c`（0xbb）→ 压入未初始化引用 | `bytecodes.hpp:231` |
| 解释器快路径 | 检查 CP 常量解析 → clinit 屏障 → `tlab_allocate` 内联指令 | `templateTable_x86.cpp:3732-3774` |
| 指令级 | **bump-pointer**：`top += size`，一条 `lea` + 一条 `cmp` + 一条 `mov` | `barrierSetAssembler_x86.cpp:281-313` |
| 慢路径 | `InterpreterRuntime::_new`：解析 klass → 校验可实例化 → 类初始化 → 分配 | `interpreterRuntime.cpp:223-235` |
| 堆分配 | `MemAllocator::mem_allocate` 三段式（fast TLAB → refill → 堆外） | `memAllocator.cpp:327-348` |
| 对象初始化 | mark word = prototype、klass 指针、字段清零 | `templateTable_x86.cpp:3792-3830` |
| 构造器 | `invokespecial <init>` | `templateTable_x86.cpp:3496` |
| C2 | `AllocateNode` → Macro 展开 → 逃逸分析/标量替换**消灭分配** | `macro.cpp:2413` · `c2_globals.hpp:584` |

---

## TOC

1. [字节码真相：`new` 只有一条指令](#1-字节码真相new-只有一条指令)
2. [解释器快路径：TemplateTable::_new](#2-解释器快路径templatetable_new)
3. [指令级 TLAB：bump-pointer 三连](#3-指令级-tlabbump-pointer-三连)
4. [慢路径：MemAllocator 三段式](#4-慢路径memallocator-三段式)
5. [对象诞生：mark word + klass + 字段清零](#5-对象诞生mark-word--klass--字段清零)
6. [构造器调用：invokespecial <init>](#6-构造器调用invokespecial-init)
7. [C2 的世界：分配如何被消灭](#7-c2-的世界分配如何被消灭)
8. [JDK 28 与教科书的差异](#8-jdk-28-与教科书的差异)
9. [验证实验](#9-验证实验)
10. [与 synchronized / volatile 的闭环](#10-与-synchronized--volatile-的闭环)

---

## 1. 字节码真相：`new` 只有一条指令

`new Foo()` 在字节码层面是**两条指令**：

```java
0: new             #7   // class Foo      ← 分配对象（未初始化引用）
3: dup                  // 复制引用（构造器返回 void，栈上还要留一份）
4: invokespecial  #12   // Method "<init>"  ← 调构造器
7: astore_1             // 存局部变量
```

`new` 的操作码定义在字节码枚举里：

```cpp
// bytecodes.hpp:231
_new                  = 187, // 0xbb
_newarray             = 188, // 0xbc
```

> **关键认知**：`new` 只负责**分配 + 半初始化**——压入栈的引用指向一个"对象头已就位、字段已清零、但构造器还没跑"的对象。`dup` + `invokespecial <init>` 才是"成为完整对象"的另一半。

### 类文件里的操作数

`new` 后面跟 2 字节的 **constant pool index**，指向一个 `CONSTANT_Class_info`。VM 拿到后要走一遍解析（resolution）才能拿到 `InstanceKlass`：

```
字节码流:  [0xbb][hi][lo]
              │
              ▼
ConstantPool::klass_at(index)  →  ClassFileParser 解析 / 复用已解析的 InstanceKlass
```

---

## 2. 解释器快路径：TemplateTable::_new

JDK 28 的解释器（template interpreter）为 `new` 生成了一段**尽量不调用运行时**的机器码模板：

```cpp
// templateTable_x86.cpp:3732
void TemplateTable::_new() {
  ...
  __ get_cpool_and_tags(rcx, rax);

  // 1️⃣ 常量池 tag 必须是 JVM_CONSTANT_Class（已解析）
  __ cmpb(Address(rax, rdx, Address::times_1, tags_offset), JVM_CONSTANT_Class);
  __ jcc(Assembler::notEqual, slow_case_no_pop);          // :3746-3747

  // 2️⃣ 加载 InstanceKlass
  __ load_resolved_klass_at_index(rcx, rcx, rdx);          // :3750

  // 3️⃣ clinit 屏障：类必须先初始化（static 关键字的地盘）
  __ clinit_barrier(rcx, nullptr /*L_fast_path*/, &slow_case);  // :3756

  // 4️⃣ 取 layout_helper：instance_size（字节数）+ 慢路径标志位
  __ movl(rdx, Address(rcx, Klass::layout_helper_offset()));    // :3759
  __ testl(rdx, Klass::_lh_instance_slow_path_bit);             // :3761
  __ jcc(Assembler::notZero, slow_case);                        // :3762
  ...
```

四个前置检查（CP 已解析 → klass 已加载 → **类已初始化** → 无慢路径标志）全部通过后，进入分配：

```cpp
  if (UseTLAB) {
    __ tlab_allocate(rax, rdx, 0, rcx, rbx, slow_case);   // :3774  ← 快路径核心
    ...
  }
```

> **`clinit_barrier` 是 `static` 关键字的渗透点**：`new Foo()` 之前，VM 必须保证 `Foo` 的 `<clinit>`（静态块 + 静态字段初始化）已经执行完。这就是为什么 `new` 能触发"静态初始化"——不是巧合，是解释器模板里写死的检查。

---

## 3. 指令级 TLAB：bump-pointer 三连

`tlab_allocate` 宏最终落到 `BarrierSetAssembler::tlab_allocate`，生成**三条核心指令**：

```cpp
// barrierSetAssembler_x86.cpp:281
void BarrierSetAssembler::tlab_allocate(MacroAssembler* masm, ...) {
  const Register thread = r15_thread;                       // x64 约定：r15 = 当前线程

  __ verify_tlab();

  __ movptr(obj, Address(thread, JavaThread::tlab_top_offset()));   // ① obj = TLAB.top
  if (var_size_in_bytes == noreg) {
    __ lea(end, Address(obj, con_size_in_bytes));                   // ② end = obj + size
  } else {
    __ lea(end, Address(obj, var_size_in_bytes, Address::times_1));
  }
  __ cmpptr(end, Address(thread, JavaThread::tlab_end_offset()));   // ③ end <= TLAB.end ?
  __ jcc(Assembler::above, slow_case);                              //    溢出 → 慢路径

  // update the tlab top pointer
  __ movptr(Address(thread, JavaThread::tlab_top_offset()), end);   // ④ TLAB.top = end（指针前移）
  ...
}
```

**这就是"bump-pointer"的全部秘密**：不搜索空闲块、不维护空闲链表，只是把线程私有的一块内存的 `top` 指针往前挪 `size` 字节。分摊下来每次分配就几条指令。

### C++ 侧同样的逻辑

解释器和 C2 的慢路径兜底调 C++ 版本，逻辑一模一样：

```cpp
// threadLocalAllocBuffer.inline.hpp:38
inline HeapWord* ThreadLocalAllocBuffer::allocate(size_t size) {
  HeapWord* obj = top();
  if (pointer_delta(end(), obj) >= size) {   // 剩余空间够吗？
    set_top(obj + size);                     // 指针前移 = 分配完成
    return obj;
  }
  return nullptr;                            // 不够 → 慢路径
}
```

> **为什么快**：TLAB 是**线程私有**的（JDK 28 里 `tlab_top` 就在线程对象 `r15_thread` 上），分配只碰自己线程的数据，**零锁、零原子操作、零 GC 交互**。这是"对象分配很快"的全部真相。

---

## 4. 慢路径：MemAllocator 三段式

TLAB 快路径失败（空间不足）时，进入 `InterpreterRuntime::_new`：

```cpp
// interpreterRuntime.cpp:223
JRT_ENTRY(void, InterpreterRuntime::_new(JavaThread* current, ConstantPool* pool, int index))
  Klass* k = pool->klass_at(index, CHECK);              // 解析（慢路径才真正解析）
  InstanceKlass* klass = InstanceKlass::cast(k);

  klass->check_valid_for_instantiation(true, CHECK);    // 抽象类/接口 → InstantiationError

  klass->initialize_preemptable(CHECK_AND_CLEAR_PREEMPTED);  // 类初始化（可抢占）

  oop obj = klass->allocate_instance(CHECK);            // → InstanceKlass::allocate_instance
  current->set_vm_result_oop(obj);
JRT_END
```

`allocate_instance` 只是转发：

```cpp
// instanceKlass.cpp:1936
instanceOop InstanceKlass::allocate_instance(TRAPS) {
  size_t size = size_helper();
  return (instanceOop)Universe::heap()->obj_allocate(this, size, THREAD);
}
// collectedHeap.inline.hpp:36
inline oop CollectedHeap::obj_allocate(Klass* klass, size_t size, TRAPS) {
  ObjAllocator allocator(klass, size, THREAD);   // MemAllocator 的子类
  return allocator.allocate();
}
```

真正的三段式分配在 `MemAllocator::mem_allocate`：

```cpp
// memAllocator.cpp:327
HeapWord* MemAllocator::mem_allocate(Allocation& allocation) const {
  if (UseTLAB) {
    HeapWord* mem = mem_allocate_inside_tlab_fast();   // ① 现有 TLAB 里再试一次
    if (mem != nullptr) return mem;
  }
  DEBUG_ONLY(...safepoint check...);

  if (UseTLAB) {
    HeapWord* mem = mem_allocate_inside_tlab_slow(allocation);  // ② refill 新 TLAB
    if (mem != nullptr) return mem;
  }
  return mem_allocate_outside_tlab(allocation);        // ③ 直接堆分配（大对象）
}
```

### ② refill 的决策逻辑（慢路径里的"聪明"部分）

```cpp
// memAllocator.cpp:253
HeapWord* MemAllocator::mem_allocate_inside_tlab_slow(Allocation& allocation) const {
  ...
  // TLAB 剩余空间小于阈值 → 丢弃整个 TLAB 换新的
  if (tlab.free() > tlab.refill_waste_limit()) {
    tlab.record_slow_allocation(_word_size);
    return nullptr;                        // 剩余空间"值得保留" → 直接堆外分配
  }

  tlab.record_refill_waste();
  _thread->retire_tlab();                  // 退休旧 TLAB
  size_t new_tlab_size = tlab.compute_size(_word_size);   // 动态计算新 TLAB 大小（ResizeTLAB）
  ...
  mem = Universe::heap()->allocate_new_tlab(min_tlab_size, new_tlab_size, ...);
  ...
  _thread->fill_tlab(mem, _word_size, allocation._allocated_tlab_size);  // 新 TLAB 里分配目标对象
  return mem;
}
```

**核心权衡**：TLAB 剩余空间**大**（> waste 阈值）→ 不值得丢掉 → 对象走堆外分配，TLAB 留给后面小对象；剩余空间**小** → 直接退休整个 TLAB，换个大号的，目标对象在 TLAB 头部拿到空间。

> **`refill_waste_limit` 还会动态增长**（`record_slow_allocation`，inline.hpp:90-105）：同一线程反复触发慢路径说明它经常分配同尺寸大对象，阈值逐步抬高，下次直接走堆外，避免反复 refill。

### ③ 大对象直接堆分配

```cpp
// memAllocator.cpp:235
HeapWord* MemAllocator::mem_allocate_outside_tlab(Allocation& allocation) const {
  allocation._allocated_outside_tlab = true;
  HeapWord* mem = Universe::heap()->mem_allocate(_word_size);   // GC 堆分配（可能触发 GC）
  ...
}
```

大对象（如巨型数组）不配 TLAB——直接向 GC 堆要，往往进老年代或专门的大对象区（G1 的 humongous）。

---

## 5. 对象诞生：mark word + klass + 字段清零

分配只是拿到裸内存，接下来解释器模板做**初始化**。回到 `_new` 模板的后半段：

```cpp
// templateTable_x86.cpp:3790-3830
  // 字段清零循环（rdx = 实例大小 - 对象头）
  __ xorl(rcx, rcx);                          // rcx = 0（清零寄存器）
  __ shrl(rdx, LogBytesPerLong);              // 长度 ÷ 8
  { Label loop;
  __ bind(loop);
  __ movptr(Address(rax, rdx, Address::times_8, header_size_bytes - 1*oopSize), rcx);  // 写 8 字节 0
  __ decrement(rdx);
  __ jcc(Assembler::notZero, loop);
  }

  __ bind(initialize_header);
  if (UseCompactObjectHeaders || Arguments::is_valhalla_enabled()) {
    ...prototype_header...
  } else {
    // mark word = prototype（unlocked + 零 hash + 零 age）
    __ movptr(Address(rax, oopDesc::mark_offset_in_bytes()),
              (intptr_t)markWord::prototype().value());
  }
  if (!UseCompactObjectHeaders) {
    __ xorl(rsi, rsi);
    __ store_klass_gap(rax, rsi);             // 压缩 oop 的 klass gap 清零
    __ store_klass(rax, rcx, rscratch1);      // 写 klass 指针
  }
```

**对象头初始化后的布局**（非 compact headers 模式）：

```
        ┌──────────────────────────────┐  ← 对象起始
mark    │ markWord::prototype()        │    unlocked(01) + hash=0 + age=0
        ├──────────────────────────────┤
klass   │ InstanceKlass 指针            │    (或 compressed klass + gap)
        ├──────────────────────────────┤
fields  │ 8 字节一组全零                │    每个字段初始值 = 0 / null / false
        └──────────────────────────────┘  ← 对象结束（size 对齐）
```

> **与 02 的闭环**：mark word 装的是 `markWord::prototype()`——就是 02 里说的 `unlocked(01)` 锁状态。此刻对象是"全新未加锁"的，第一次 `synchronized` 才会在它身上演锁升级。

---

## 6. 构造器调用：invokespecial <init>

对象半初始化完成后，栈上是一个引用，接下来 `invokespecial` 调 `<init>`：

```cpp
// templateTable_x86.cpp:3496
void TemplateTable::invokespecial(int byte_no) {
  ...
}
```

`<init>` 是构造器编译出来的特殊方法（名字固定为 `<init>`、返回 void）。调用完成后对象才算"完全初始化"。

> **两个隐蔽规则**：
> - `new` 之后**必须**紧跟一次 `<init>` 调用——JVM 在验证阶段（`ClassVerifier`）检查"未初始化引用不得逃逸"，比如 `new` 出来的对象不能提前存进数组或字段再调构造器（违者 `VerifyError`）。
> - **编译期型关键字的体现**：`var` 等关键字在 class 文件里没有痕迹，而 `new` 有——因为 `new` 是**机制型**，背后是真实的分配机制；`var` 只是类型推断，javac 阶段就消解了。

---

## 7. C2 的世界：分配如何被消灭

解释器只是"能用"，真正让分配快的杀招在 C2（JIT 编译器）里——**逃逸分析可以把 `new` 整个删掉**。

### AllocateNode

C2 把 `new` 建模为一个特殊的调用节点：

```cpp
// callnode.hpp:1112
class AllocateNode : public CallNode { ... };
// callnode.hpp:1234
class AllocateArrayNode : public AllocateNode { ... };
```

后续在宏展开阶段（`PhaseMacroExpand`）被降级为真正的分配代码：

```cpp
// macro.cpp:2413
void PhaseMacroExpand::expand_allocate(AllocateNode *alloc) { ... }
```

### 标量替换（Scalar Replacement）

```cpp
// c2_globals.hpp:584
product(bool, EliminateAllocations, true, ...)
```

```cpp
// escape.cpp:416
if (has_scalar_replaceable_candidates && EliminateAllocations) { ... }
```

**流程**：
1. **逃逸分析**：分析 `new Foo()` 出来的对象有没有逃出当前方法/线程。
2. **未逃逸** → **标量替换**：对象被拆成若干标量（字段值），直接在寄存器/栈槽里传递，**分配动作被删除**。
3. **部分逃逸** → 只在逃逸分支分配。

> 典型例子：`Point p = new Point(x, y); return p.x + p.y;` 这种局部对象在 C2 下**根本不分配内存**——`p` 被拆成 `x`、`y` 两个值，`new` 的分配被删掉，直接算加法。所以"`new` 很慢"在 JIT 眼里不一定成立。

### 锁消除的配合

`EliminateLocks` 与标量替换配合：未逃逸对象上的 `synchronized` 也会被删掉——因为**没有其他线程能看到这个对象**，锁毫无意义。这正好呼应 02 的锁升级：**锁的成本取决于对象是否逃逸**。

---

## 8. JDK 28 与教科书的差异

| 教科书说法 | JDK 28 真相 | 源码证据 |
|---|---|---|
| `new` 一定分配内存 | **不一定**——未逃逸对象被标量替换，分配被删除 | `escape.cpp:416` · `EliminateAllocations=true` |
| 分配要锁堆 | TLAB 线程私有，bump-pointer **零锁** | `barrierSetAssembler_x86.cpp:296-306` |
| TLAB 大小固定 | **ResizeTLAB 动态调整**，refill 多了自动翻倍（最多 16×） | `threadLocalAllocBuffer.inline.hpp:57-68` |
| 慢路径就分配大对象 | 慢路径先做"剩余空间 vs waste 阈值"**权衡**，剩余多反而走堆外 | `memAllocator.cpp:276` |
| 对象头要写两次（mark + klass） | **UseCompactObjectHeaders 可合成单 64 位头**（Valhalla 配套） | `templateTable_x86.cpp:3818` |
| `new` 只是"分配" | `new` 必须过 **clinit 屏障**（`static` 的渗透） | `templateTable_x86.cpp:3756` |

---

## 9. 验证实验

### 实验 A：TLAB 日志

```bash
java -Xlog:gc+tlab=debug TLABDemo
```

能看到每个线程的 TLAB 分配/refill 记录，验证"快路径 → refill → 堆外"三段式。

### 实验 B：逃逸分析效果

```java
public class EscapeDemo {
  static long sum() {
    long s = 0;
    for (int i = 0; i < 100_000_000; i++) {
      Point p = new Point(i, i);   // 未逃逸
      s += p.x + p.y;
    }
    return s;
  }
}
```

对比 `-XX:+EliminateAllocations` / `-XX:-EliminateAllocations` 的吞吐差异——关闭后分配真实发生，性能断崖式下跌。

### 实验 C：看 JIT 汇编

```bash
java -XX:+UnlockDiagnosticVMOptions -XX:+PrintAssembly -Xcomp -XX:TieredStopAtLevel=4 EscapeDemo
```

未逃逸对象的 `new` 在汇编里**没有** `call` 到分配 stub，只有寄存器操作——分配被消灭的铁证。

---

## 10. 与 synchronized / volatile 的闭环

| 关键字 | 背后机制 | 关联点 |
|---|---|---|
| `new` | TLAB + MemAllocator + 逃逸分析 | 对象的"出生证明"：mark word = prototype（unlocked） |
| `synchronized` | 锁升级 | 出生时 unlocked(01)，第一次加锁才演升级；未逃逸对象的锁被 `EliminateLocks` 删除 |
| `volatile` | 内存屏障 | 构造器里的 `final`/`volatile` 写要在出口插屏障（parse1.cpp:1108），保证发布安全 |
| `static` | `<clinit>` | `new` 的 clinit 屏障保证类先初始化 |

**完整故事**：`new Foo()` 先过 clinit 屏障（static 的地盘）→ TLAB 拿内存 → 对象头 = prototype（unlocked，synchronized 的起点）→ 字段清零 → `<init>` 里可能有 volatile/final 写（屏障保护发布）→ 如果对象没逃逸，C2 把这一切都删掉，只留标量运算。

---

*下一篇候选：`static` 关键字 —— `<clinit>` 类初始化主流程（`instanceKlass.cpp:1417` initialize_impl）。*
