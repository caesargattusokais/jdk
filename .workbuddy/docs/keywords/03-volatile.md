# 03 · volatile：一条内存屏障的完整旅程

> **快速概览**：`volatile` 是 Java 里唯一一个"**类文件无痕、运行时重拳**"的关键字——字节码里没有任何专属指令，只有一个访问标志位；真正的工作全部发生在 C2 编译期（插入屏障节点）和机器码层（x86 上一条 `lock addl`）。本文从 JMM 语义出发，沿 `ACC_VOLATILE → C2 barrier 插入 → x86 机器码` 全链路跟读，并用真实行号回答三个问题：屏障插在哪？为什么 x86 只有写侧有真指令？`volatile` 和 `synchronized` 到底差在哪？

---

## 目录

- [1. volatile 的 JMM 语义：它承诺了什么](#1-volatile-的-jmm-语义它承诺了什么)
- [2. 字节码层面：无痕（classFileParser.cpp:4626）](#2-字节码层面无痕classfileparsercpp4626)
- [3. C2 的识别与屏障插入（parse3.cpp / barrierSetC2.cpp）](#3-c2-的识别与屏障插入parse3cpp--barriersetc2cpp)
- [4. x86 机器码真相：Acquire/Release 是空的（x86.ad）](#4-x86-机器码真相acquirerelease-是空的x86ad)
- [5. OrderAccess：运行时的屏障 API（orderAccess.hpp）](#5-orderaccess运行时的屏障-apiorderaccesshpp)
- [6. happens-before 与四类重排](#6-happens-before-与四类重排)
- [7. DCL 单例实战：构造器屏障收尾（parse1.cpp:1108）](#7-dcl-单例实战构造器屏障收尾parse1cpp1108)
- [8. volatile vs synchronized 对比](#8-volatile-vs-synchronized-对比)
- [9. 验证实验](#9-验证实验)

---

## 1. volatile 的 JMM 语义：它承诺了什么

JLS 17 对 volatile 的完整承诺，浓缩成三句话：

| 承诺 | 含义 | JMM 条款 |
|---|---|---|
| **可见性** | 写 volatile 的线程，其"写之前"的所有写操作对后续读该 volatile 的线程**可见** | happens-before：volatile 写 → volatile 读 |
| **有序性** | volatile 读写**不参与重排**：读写自身及其周边的普通读写都不能越过它 | 四类屏障（见 §6） |
| **原子性** | 仅保证**单个 volatile 读/写**是原子的（如 `long/double` 不撕裂） | 不保证 `i++` 这种复合操作 |

关键认知：**volatile 是"单点栅栏"，不是"互斥区"**。它保证的是内存操作的顺序与可见性，不保证多个操作的组合原子性——`volatile int i; i++;` 依然不是线程安全的。

**一个容易踩的误区**：可见性不是"读一定拿到最新值"（那是顺序一致性的奢侈要求），而是"**在 happens-before 关系成立的前提下**，读能拿到写的结果"。happens-before 链怎么建立，看 §6。

---

## 2. 字节码层面：无痕（classFileParser.cpp:4626）

`volatile` 在 class 文件里**没有专属字节码**。`getfield/putfield` 照常使用，唯一区别是 `access_flags` 里的 `ACC_VOLATILE` 位（0x0040）：

```
putfield #12   // Field x:I  ← 普通字段
putfield #12   // Field x:I  ← volatile 字段（flags 多一个 ACC_VOLATILE）
```

JVM 读取这个标志位的落点：

```cpp
// classFileParser.cpp:4626
const bool is_volatile  = (flags & JVM_ACC_VOLATILE)    != 0;
```

`is_volatile` 随后被写入 `FieldInfo`（字段元数据），成为 `ciField::is_volatile()` 的数据来源——这是整条链路**唯一的识别入口**。之后：

- **解释器**：不区分 volatile，`getfield/putfield` 模板照常执行（x86 强内存模型下普通 mov 即可，硬件保证单字读写原子）；
- **C1**：只在 `StoreLoad` 场景插 `membar`（c1_LIRAssembler_x86.cpp:3327 注释：*"No x86 machines currently require load fences"*）；
- **C2**：重头戏，见 §3。

> 对比 `synchronized`：后者有专属字节码 `monitorenter/monitorexit`（bytecodes.hpp:238，0xc2），所以"字节码无痕"是 volatile 区别于 synchronized 的第一道分水岭。

---

## 3. C2 的识别与屏障插入（parse3.cpp / barrierSetC2.cpp）

### 3.1 解析：volatile → MO_SEQ_CST decorator

C2 解析 `getfield/putfield` 的统一入口是 `Parse::do_field_access`（parse3.cpp:47），按读写分发到 `do_get_xxx`（112 行）与 `do_put_xxx`（258 行）。volatile 的判定在写入侧：

```cpp
// parse3.cpp:259
bool is_vol = field->is_volatile();
...
// parse3.cpp:317-320
DecoratorSet decorators = IN_HEAP;
decorators |= is_vol ? MO_SEQ_CST : MO_UNORDERED;
inc_sp(1);
access_store_at(obj, adr, adr_type, val, field_type, bt, decorators);
```

**MO_SEQ_CST**（memory order sequential consistency，access 装饰器体系）是整条链路的"口令"：普通字段是 `MO_UNORDERED`（弱序，允许重排），volatile 是 `MO_SEQ_CST`（全序）。读侧同样在 `do_get_xxx` 里打上 `MO_SEQ_CST`（parse3.cpp:198）。

### 3.2 插屏障：BarrierSetC2 的 C2AccessFence

`access_store_at / access_load_at` 最终进入 `BarrierSetC2`，屏障插入由 RAII 对象 `C2AccessFence` 完成——**构造时插"前屏障"，析构时插"后屏障"**：

```cpp
// barrierSetC2.cpp:262-263  —— 从 decorators 提取语义
bool is_volatile = (decorators & MO_SEQ_CST) != 0;
bool is_release  = (decorators & MO_RELEASE) != 0;

// barrierSetC2.cpp:280-287  —— 写（store）之前
} else if (is_write) {
  if (is_volatile || is_release) {
    _leading_membar = kit->insert_mem_bar(Op_MemBarRelease);  // 写前屏障
  }
}

// barrierSetC2.cpp:353-360  —— 读（load）之后
} else {
  if (is_volatile || is_acquire) {
    Node* mb = kit->insert_mem_bar(Op_MemBarAcquire, n);       // 读后屏障
    mb->as_MemBar()->set_trailing_load();
  }
}

// barrierSetC2.cpp:343-352  —— 写（store）之后（仅非多拷贝原子 CPU）
} else if (is_write) {
  if (is_volatile && !support_IRIW_for_not_multiple_copy_atomic_cpu) {
    Node* mb = kit->insert_mem_bar(Op_MemBarVolatile, n);      // 写后胖屏障
  }
}
```

对应的 IR 结构（**volatile 写**两侧都有屏障，**volatile 读**只有读后屏障）：

```
          [MemBarRelease]          ← 写前：防前面操作下沉
                ↓
           Store(volatile)         ← 写本身（MemNode::release 语义）
                ↓
          [MemBarVolatile]         ← 写后：防后面操作上浮（x86 上才变真指令）
                ↓

          Load(volatile)           ← 读本身（MemNode::acquire 语义）
                ↓
          [MemBarAcquire]          ← 读后：防后续操作上浮
```

### 3.3 内存序：MemNode 的 mem_node_mo()

volatile 读写节点自身的顺序语义由 `C2Access::mem_node_mo()` 决定（barrierSetC2.cpp:377-389）：

```cpp
if ((_decorators & MO_SEQ_CST) != 0) {
  if (is_write && is_read)      return MemNode::seqcst;   // 原子操作（LoadStore）
  else if (is_write)            return MemNode::release;  // volatile 写
  else                          return MemNode::acquire;  // volatile 读
}
```

这个语义被 C2 的全局内存排序分析（`PhaseIdealLoop` 中的 store-load 重排检查）使用，保证 IR 层面的顺序不被乱优化——即使目标机器最终不需要真屏障。

---

## 4. x86 机器码真相：Acquire/Release 是空的（x86.ad）

C2 的屏障节点最终要匹配成机器指令。x86 的 AD 文件给出了反直觉的答案——**大部分屏障是零指令**：

```adl
// x86.ad:8855-8865  —— acquire 屏障：空编码
instruct membar_acquire() %{
  match(MemBarAcquire);
  match(LoadFence);
  ins_cost(0);
  size(0);
  format %{ "MEMBAR-acquire ! (empty encoding)" %}
  ins_encode();
  ins_pipe(empty);
%}

// x86.ad:8878-8888  —— release 屏障：空编码
instruct membar_release() %{
  match(MemBarRelease);
  match(StoreFence);
  ins_cost(0);
  size(0);
  format %{ "MEMBAR-release ! (empty encoding)" %}
  ins_encode();
  ins_pipe(empty);
%}

// x86.ad:8916-8929  —— volatile（胖）屏障：唯一有真指令的
instruct membar_volatile(rFlagsReg cr) %{
  match(MemBarVolatile);
  effect(KILL cr);
  ins_cost(400);
  format %{
    $$template
    $$emit$$"lock addl [rsp + #0], 0\t! membar_volatile"
  %}
  ins_encode %{
    __ membar(Assembler::StoreLoad);
  %}
  ins_pipe(pipe_slow);
%}
```

为什么？**因为 x86 是强内存模型（TSO）**：

- **Acquire/Release 空编码**：x86 的普通 load/store 不会跟别的 load/store 重排（只有 store 可能滞后于后续 load 被看到，即 StoreLoad 重排）。acquire 要防的"后续操作上浮到读之前"和 release 要防的"先前操作下沉到写之后"，x86 硬件天然不犯——所以空编码完全满足语义，只留下**编译器屏障**（`ins_encode()` 空，但 IR 层面 ordering 已锁定，C2 不会乱调序）。
- **StoreLoad 必须真指令**：`lock addl [rsp],0` 是一条"假装在内存上做加法"的**全屏障**——它让 CPU 把 store buffer 排空，保证之前的写对所有核可见，之后任何核的读都能看到。这就是 x86 上 volatile 写唯一付出的真实代价。

还有一条**优化规则**（x86.ad:8931-8941）：当 Matcher 判定该 volatile 屏障"不必要"（比如相邻已有更重的屏障）时，匹配为 `unnecessary_membar_volatile`，同样是空编码。

**结论**：在 x86 上，一个 `volatile` 字段写 = 普通 mov + 一条 `lock addl [rsp],0`；一个 `volatile` 字段读 = 普通 mov（零额外指令）。代价远小于教科书渲染的"每次读写都上锁"。

---

## 5. OrderAccess：运行时的屏障 API（orderAccess.hpp）

C2 管 Java 字节码，OrderAccess 管 **HotSpot 自身 C++ 代码**的内存序。它定义了四类基础屏障 + 三个组合语义：

```cpp
// orderAccess.hpp:238-248
class OrderAccess : public AllStatic {
  static void loadload();      // 读读屏障
  static void storestore();    // 写写屏障
  static void loadstore();     // 读写屏障
  static void storeload();     // 写读屏障 ← 最难的一道
  static void acquire();       // = loadload + loadstore（读后的屏障）
  static void release();       // = storestore + loadstore（写前的屏障）
  static void fence();         // = 全屏障（四类全含）
};
```

Windows x86 的实现（orderAccess_windows_x86.hpp:42-53）再次印证"x86 只需要一道真指令"：

```cpp
// orderAccess_windows_x86.hpp
inline void OrderAccess::loadload()   { compiler_barrier(); }  // _ReadWriteBarrier，零指令
inline void OrderAccess::storestore() { compiler_barrier(); }
inline void OrderAccess::loadstore()  { compiler_barrier(); }
inline void OrderAccess::storeload()  { fence(); }             // 唯一需要真屏障的

inline void OrderAccess::fence() {
  StubRoutines_fence();    // 生成代码里的 membar(StoreLoad)
  compiler_barrier();
}
```

`StubRoutines_fence` 最终指向 VM 启动早期生成的 stub（stubGenerator_x86_64.cpp:584-602），核心就是一条 `__ membar(Assembler::StoreLoad)`；而 `Assembler::membar` 的汇编层实现只处理 StoreLoad（assembler_x86.cpp:208-242）：

```cpp
// assembler_x86.cpp:208-241（节选）
void Assembler::membar(Membar_mask_bits order_constraint) {
  // We only have to handle StoreLoad
  if (order_constraint & StoreLoad) {
    int offset = -VM_Version::L1_line_size();
    if (offset < -128) offset = -128;
    lock();
    addl(Address(rsp, offset), 0);   // lock addl $0,-128(%rsp)
  }
}
```

> 设计细节：`lock addl` 的目标选在 `rsp` 下方（负偏移），避免与当前方法栈帧冲突，且几乎总在数据缓存里——所以这条"昂贵的全屏障"实际开销远低于 `mfence`/`cpuid`（旧实现）的方案。

---

## 6. happens-before 与四类重排

JMM 对重排的约束可以浓缩为**四类读写顺序**（程序顺序下）：

| 屏障 | 禁止的重排 | volatile 何时需要 | x86 真指令 |
|---|---|---|---|
| LoadLoad | 两次读互相调换 | volatile 读之后，后续读不上浮 | 无（空编码） |
| StoreStore | 两次写互相调换 | volatile 写之前，先前写不下沉 | 无（空编码） |
| LoadStore | 读与后续写调换 | volatile 读后、写前双向 | 无（空编码） |
| StoreLoad | 写与后续读调换 | **volatile 写之后，后续读不提前** | `lock addl [rsp],0` |

**happens-before 链的建立**（JMM §17.4.5）：

```
线程 A：                    线程 B：
x = 1;          （普通写）
flag = true;    （volatile 写）──┐
                               │ StoreLoad（lock addl）
                               │ 建立了 A→B 的 hb 边
                               ├───────────────► if (flag) {   （volatile 读）
                                                int y = x;    （普通读，必见 1）
```

当 B 读到 `flag == true` 时，**A 在 volatile 写之前的全部写操作（含普通写 x=1）都对 B 可见**。这就是 volatile 可见性承诺的完整机制——不是"变量本身特殊"，而是"volatile 操作在内存总线上画了一条分界线"。

**一条关键的推论**：如果 B 读的不是 volatile（比如 `if (x != 0)`），那么即使 flag 是 volatile，也不保证看到 x=1——happens-before 链断了。

---

## 7. DCL 单例实战：构造器屏障收尾（parse1.cpp:1108）

双重检查锁（DCL）是 volatile 最经典的应用：

```java
class Singleton {
  private static volatile Singleton instance;
  static Singleton get() {
    if (instance == null) {                    // ① 快速路径（无锁读）
      synchronized (Singleton.class) {         // ② 慢速路径（锁内二次检查）
        if (instance == null) {
          instance = new Singleton();          // ③ 发布
        }
      }
    }
    return instance;
  }
}
```

没有 volatile 时，③ 的"发布"可能被重排成"先写引用、后跑构造器"，另一个线程在 ① 读到非 null 的半成品。volatile 阻止了这种重排——但注意，**单靠 volatile 写侧屏障还不够**，还需要构造器内的收尾屏障（否则 `new` 内部的字段写在离开构造器时仍可能晚于引用发布被看见）。这个屏障由 C2 在构造器出口插入：

```cpp
// parse1.cpp:1108-1114 —— do_exits：构造器出口屏障
if (method()->is_object_constructor() &&
     (wrote_non_strict_final() || wrote_stable() ||
       (AlwaysSafeConstructors && wrote_fields()) ||
       (support_IRIW_for_not_multiple_copy_atomic_cpu && wrote_volatile()))) {
  Node* recorded_alloc = alloc_with_final_or_stable();
  _exits.insert_mem_bar(UseStoreStoreForCtor ? Op_MemBarStoreStore : Op_MemBarRelease,
                        recorded_alloc);
```

对应关系：

| 场景 | 屏障 | 位置 |
|---|---|---|
| 构造器写了 final/@Stable 字段 | `Op_MemBarStoreStore` 或 `Op_MemBarRelease` | parse1.cpp:1113 |
| 写 volatile 字段（非多拷贝原子 CPU，如 PPC64） | 同上 | parse1.cpp:1111 |
| x86（多拷贝原子） | 不需要（final 屏障已够） | — |

**结论**：在 x86 上 DCL 的安全由两层保证——`new` 的分配屏障 + 构造器出口的 StoreStore/Release 屏障（final 语义）+ volatile 写的 `lock addl`。任何一层缺失都会出半成品问题。

---

## 8. volatile vs synchronized 对比

| 维度 | `volatile` | `synchronized` |
|---|---|---|
| 字节码 | 无专属指令，仅 `ACC_VOLATILE` 标志（classFileParser.cpp:4626） | `monitorenter/monitorexit`（bytecodes.hpp:238） |
| 语义 | 单变量读写原子 + 可见性 + 有序性 | 互斥 + 可见性 + 有序性（临界区全序） |
| 复合操作 | 不安全（`i++` 仍是竞态） | 安全（整段临界区串行化） |
| 阻塞 | 永不阻塞（无锁） | 可能阻塞（锁膨胀后 park） |
| 实现机制 | C2 插 MemBar 节点 + x86 `lock addl` | monitor 体系：fast-lock → 膨胀 → ObjectMonitor（见 02 篇） |
| 适用 | 状态标志、DCL 单例、发布不可变对象 | 复合操作、临界区、条件等待 |

一句话：**volatile 是"信号灯"，synchronized 是"收费站"**——信号灯只管顺序和可见性，收费站才管独占。

---

## 9. 验证实验

### 9.1 用 `-XX:+PrintAssembly` 看真实指令

```bash
java -XX:+UnlockDiagnosticVMOptions -XX:+PrintAssembly -Xbatch -Xcomp \
     -XX:CompileCommand=compileonly,VolatileDemo::write VolatileDemo
```

在编译产物中定位 volatile 写入点，应看到：

```asm
mov    0x10(%rsi),%eax          ; 普通字段读
...
mov    %eax,0x10(%rsi)          ; volatile 写本体（普通 mov）
lock addl $0x0,-0x80(%rsp)      ; ← volatile 屏障（membar_volatile）
```

而 volatile 读附近**没有**真指令——印证 §4 的结论。

### 9.2 用 `-XX:+PrintIdeal` 看 IR 屏障节点

```bash
java -XX:+UnlockDiagnosticVMOptions -XX:+PrintIdeal VolatileDemo
```

可以看到 `MemBarRelease`（写前）、`MemBarVolatile`（写后）节点贴在 Store 两侧；volatile 读只有 `MemBarAcquire`（读后）。

### 9.3 用 jhsdb / 反射验证 ACC_VOLATILE 标志

```bash
javap -v VolatileDemo.class | grep -A2 "Field x"
```

输出里 `flags: ACC_VOLATILE` 就是 §2 说的那个位的直接证据。

---

## 核心文件索引

| 文件 | 关键行 | 内容 |
|---|---|---|
| `classfileParser.cpp` | 4626 | `ACC_VOLATILE` 标志读取（唯一识别入口） |
| `parse3.cpp` | 47 / 112 / 198 / 258 / 259 / 318 | `do_field_access` → `do_get_xxx` / `do_put_xxx` → `MO_SEQ_CST` |
| `barrierSetC2.cpp` | 262-298 / 313-362 / 377-389 | `C2AccessFence` 屏障插入 + `mem_node_mo()` 内存序 |
| `x86.ad` | 8855 / 8878 / 8916 / 8931 | Acquire/Release 空编码、Volatile=`lock addl`、unnecessary 优化 |
| `orderAccess.hpp` | 238-248 | `loadload/storestore/loadstore/storeload/acquire/release/fence` |
| `orderAccess_windows_x86.hpp` | 42-53 | x86 实现：前三类零指令，storeload=fence |
| `stubGenerator_x86_64.cpp` | 584-602 | fence stub：`membar(StoreLoad)` |
| `assembler_x86.cpp` | 208-242 | `membar` 汇编：`lock; addl(rsp,offset),0` |
| `parse1.cpp` | 1069-1114 | `do_exits` 构造器出口屏障（final/volatile 收尾） |
| `memnode.hpp` | 1227 / 1351 / 1376 / 1394 | MemBarNode 家族（Volatile/StoreStore/CPUOrder） |

---

> **阅读顺序建议**：`Object.java` 的 `synchronized` 认知（02 篇）→ 本文 §2（无痕）→ §3（C2 插屏障）→ §4（x86 空编码的真相）→ §7（DCL 实战闭环）。下一篇候选：`new` 的对象分配（TLAB 快路径）。
