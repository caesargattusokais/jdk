# 05 · 代码生成与 nmethod 落地：Compile::Optimize 之后的最后一公里

> 方法调用全链路 · 第五站 | 基于 OpenJDK 28 mainline 源码（本地 D:\project\jdk 核实）

## 快速概览

第四站 `Compile::Optimize()` 把方法调用"赌"成了直接调用/内联，赌注写在了 IR 图里。**这一站讲赌注如何兑现：IR 图 → 机器码 → nmethod 挂牌上岗，以及赌输了之后如何撤回（去优化/失效）。**

全链路五段，全部在本站覆盖：

```
C2Compiler::compile_method (c2compiler.cpp:125)
  └─ Compile C(...) 构造 (compile.cpp:659)
       ├─ :887 Optimize()      ← 第四站：doCall/bytecodeInfo 决策
       └─ :946 Code_Gen()      ← 本站① 指令选择 → ② 寄存器分配 → ③ 机器码生成
            └─ PhaseOutput::install (output.cpp:3302)
                 └─ ciEnv::register_method (ciEnv.cpp:977)
                      ├─ 门禁：锁 + 失效检查 + 依赖编码校验 (:1008-1061)
                      └─ nmethod::new_nmethod (nmethod.cpp:1090)
                           ├─ 依赖登记：按类挂载 (nmethod.cpp:1149)
                           └─ make_in_use + Method::set_code 挂牌 (ciEnv.cpp:1110 / method.cpp:1441)
                                └─ 失效：make_not_entrant (nmethod.cpp:2215) → 状态机 → 重编译
```

**四个灵魂问题，一站答全：**

| # | 问题 | 答案（源码锚点） |
|---|------|------|
| 1 | IR 怎么变成 x86 指令？ | `Matcher::match`（compile.cpp:3805）Ideal→Mach，逐节点匹配指令模板 |
| 2 | 寄存器不够怎么办？ | `PhaseChaitin::Register_Allocate`（chaitin.cpp:356）图着色 + 溢出（spill） |
| 3 | 机器码怎么进 CodeCache 并开始执行？ | `PhaseOutput::install` → `register_method` → `new_nmethod` → `make_in_use` + `Method::set_code` 挂牌 |
| 4 | 赌输了怎么撤？ | `make_not_entrant`（nmethod.cpp:2215）入口 patch + `inc_decompile_count`，状态机 `in_use → not_entrant`，GC 后 unlink/purge |

---

## 目录

- [1. 驱动主流程：编译是怎么被调起来的](#1-驱动主流程编译是怎么被调起来的)
- [2. 指令选择：Matcher 把 Ideal 变成 Mach](#2-指令选择matcher-把-ideal-变成-mach)
- [3. CFG 与全局代码移动：PhaseCFG](#3-cfg-与全局代码移动phasecfg)
- [4. 寄存器分配：Chaitin 图着色](#4-寄存器分配chaitin-图着色)
- [5. 块排序、窥孔与晚期展开](#5-块排序窥孔与晚期展开)
- [6. 机器码生成：PhaseOutput](#6-机器码生成phaseoutput)
- [7. 入口偏移定址：verified/osr 双入口](#7-入口偏移定址verifiedosr-双入口)
- [8. 安装门禁：register_method 的六道检查](#8-安装门禁register_method-的六道检查)
- [9. nmethod 创建：new_nmethod 的空间账本](#9-nmethod-创建new_nmethod-的空间账本)
- [10. 依赖登记：按类挂载的"把柄"](#10-依赖登记按类挂载的把柄)
- [11. 挂牌上岗：make_in_use 与 Method::set_code](#11-挂牌上岗make_in_use-与-methodset_code)
- [12. 赌输撤回：make_not_entrant 去优化](#12-赌输撤回make_not_entrant-去优化)
- [13. 回收与状态机：从 not_entrant 到 purge](#13-回收与状态机从-not_entrant-到-purge)
- [14. 五站闭环：一条 invokevirtual 的一生](#14-五站闭环一条-invokevirtual-的一生)
- [15. 行号速查表](#15-行号速查表)

---

## 1. 驱动主流程：编译是怎么被调起来的

一切从 `C2Compiler::compile_method` 开始（**c2compiler.cpp:125**）：

```cpp
// c2compiler.cpp:125
void C2Compiler::compile_method(ciEnv* env, ciMethod* target, int entry_bci,
                                bool install_code, DirectiveSet* directive) {
  ...
  while (!env->failing()) {
    Options options(subsume_loads, do_escape_analysis, ...);
    Compile C(env, target, entry_bci, options, directive);   // :149 整次编译在构造里跑完

    if (C.failure_reason() != nullptr) {
      if (C.failure_reason_is(retry_no_subsuming_loads())) { // :153 降级：不再把 load 并入指令
        subsume_loads = false;
        continue;  // retry
      }
      if (C.failure_reason_is(retry_no_escape_analysis())) { // :159 降级：关掉逃逸分析
        do_escape_analysis = false;
        continue;  // retry
      }
      ...
```

**关键点：一次编译的成败以"可安装"为界。** `Compile` 构造函数（**compile.cpp:659**）内部顺序执行两大阶段：

```cpp
// compile.cpp:887 / :946（Compile 构造函数内）
Optimize();   // 第四站：IR 优化 + doCall 去虚化/内联决策
Code_Gen();   // 本站：指令选择 → 寄存器分配 → 机器码
```

失败时不是立即放弃，而是**降级重试**：先关掉 `SubsumeLoads`（load 并入机器指令），再关掉 `DoEscapeAnalysis`——越退越保守，但总能编译出来。第二构造函数（OSR 编译等场景）同样在 **:1071** 调 `Code_Gen()`。

## 2. 指令选择：Matcher 把 Ideal 变成 Mach

`Code_Gen`（**compile.cpp:3790**）的第一件事：

```cpp
// compile.cpp:3805-3813
Matcher matcher;
_matcher = &matcher;
{
  TracePhase tp(_t_matcher);
  matcher.match();          // :3809 指令选择
  if (failing()) return;
}
// :3795-3799 注释：Matcher 不能回收——生成 spill 代码还要用它
```

`Matcher::match`（**matcher.cpp:216**）做的是**树匹配**：以 Ideal 节点为根，把平台无关的操作树（AddI、LoadI、CallDynamicJava……）逐棵匹配到 x86 指令模板（MachNode），模板里直接编码了指令的编码方式、寻址模式、副作用。

- **Ideal 图**：平台无关、SSA 形式、节点数量级大（第四站的产物）
- **Mach 图**：平台相关、每条对应一条（或几条）真实指令

匹配之后，`check_node_count`（:3819）再查一次节点预算，超限就 bail out。

## 3. CFG 与全局代码移动：PhaseCFG

匹配完 Mach 节点，需要把它们排成真正的控制流图：

```cpp
// compile.cpp:3827-3845
PhaseCFG cfg(node_arena(), root(), matcher);
_cfg = &cfg;
{
  TracePhase tp(_t_scheduler);
  bool success = cfg.do_global_code_motion();   // :3834 全局代码移动（调度）
  ...
  cfg.verify();
}
```

`PhaseCFG` 把 Mach 节点按控制依赖组织成基本块；`do_global_code_motion` 是**指令调度**——在保持数据依赖/控制依赖的前提下重排指令，把内存延迟藏到计算后面（x86 上的收益主要来自减少停顿，相比 IA64 的显式调度要保守）。

## 4. 寄存器分配：Chaitin 图着色

```cpp
// compile.cpp:3847-3861
PhaseChaitin regalloc(unique(), cfg, matcher, false);
_regalloc = &regalloc;
{
  TracePhase tp(_t_registerAllocation);
  _regalloc->Register_Allocate();               // :3854
}
// :3851-3852 注释：分配后 use-def 链不再准确，只能信 Node→LRG→reg 映射
```

`PhaseChaitin::Register_Allocate`（**chaitin.cpp:356**）的经典三步：

```cpp
// chaitin.cpp:380-393
PhaseLive live(_cfg, _lrg_map.names(), &live_arena, false);  // ① 活性分析
PhaseIFG ifg(&live_arena);                                   // ② 干涉图
_ifg = &ifg;
...
de_ssa();   // ③ 出 SSA：Phi 的输入输出共用同一寄存器，
            //    插入"虚拟拷贝"（先不落地，能合并则合并）
```

- **PhaseLive**：每个程序点的变量活性（live-in/live-out）
- **PhaseIFG**：干涉图——两个 live range 同时活跃则连边，相邻不能同色
- **de_ssa**：SSA 的 Phi 语义要求同一寄存器，这里结束 SSA 形式；插入的虚拟拷贝后续用合并（coalescing）消化，消不掉才落成真拷贝指令
- 之后是着色（图着色）、溢出（spill，栈上放不下就存内存）、`post_allocate_copy_removal` 删拷贝

分配完成后 :3870 起做收尾：`remove_empty_blocks`（分配前留着给 spill 用的空块可以删了）、`PhaseBlockLayout` 按执行频率重排块（热块连一起，`do_freq_based_layout`）、`set_loop_alignment`、`fixup_flow`、`remove_unreachable_blocks`。

## 5. 块排序、窥孔与晚期展开

```cpp
// compile.cpp:3882-3895
if (OptoPeephole) {
  PhasePeephole peep(_regalloc, cfg);
  peep.do_transform();                            // :3886 窥孔优化
}
if (Matcher::require_postalloc_expand) {
  cfg.postalloc_expand(_regalloc);                // :3893 x86 晚期展开
}
```

- **PhasePeephole**（:3883）：寄存器分配之后，看相邻几条指令能不能合并成一条更优的（比如 `mov` 后紧跟 `add` 改写成 `add` 带内存操作数）
- **postalloc_expand**（:3891）：x86 特有——某些 CPU 需要的指令在分配后才展开（`require_postalloc_expand` 为真时），因为展开会引入新的临时寄存器需求

## 6. 机器码生成：PhaseOutput

```cpp
// compile.cpp:3904-3912
{
  TracePhase tp(_t_output);
  PhaseOutput output;                             // :3907
  output.Output();                                // :3908 MachNode → CodeBuffer
  if (failing()) return;
  output.install();                               // :3910 安装
}
// :3915-3916 He's dead, Jim. —— _cfg/_regalloc 置毒
```

`PhaseOutput`（**output.cpp:210**，CodeBuffer 取名 `"Compile::Fill_buffer"`）的 `Output()`（**output.cpp:253**）做这几件事：

```cpp
// output.cpp:270-275  ① 用 MachPrologNode 替换 StartNode（生成函数序言）
MachPrologNode* prolog = new MachPrologNode(&verified_entry);
entry->map_node(prolog, 0);
...
// output.cpp:294-297  ② 非静态方法插入未验证入口 MachUEPNode
} else if (!C->method()->is_static()) {
  C->cfg()->insert(broot, 0, new MachUEPNode());
}
// output.cpp:311-312  ③ 每个 return 前插入 epilog
for (uint i = 0; i < C->cfg()->number_of_blocks(); i++) { ... }
// output.cpp:1883    ④ Deopt handler：_code_offsets.set_value(CodeOffsets::Deopt, ...)
```

- **prolog**：函数序言（建栈帧、保存 callee-saved 寄存器）——用专门的 MachPrologNode 替换抽象的 StartNode
- **MachUEPNode**：未验证入口（unverified entry point）——虚方法调用方可能带错误 receiver 类型进来，这里做类检查后跳转
- **epilog**：每个返回点前的收尾（恢复寄存器、撤栈帧）
- **Deopt handler**（:1883）：去优化例程——第四站守卫菱形 miss 后 `uncommon_trap` 的落点

`Output()` 把每条 MachNode emit 成字节写进 CodeBuffer，同时收集：重定位信息（relocation）、OopMap（GC 安全点扫描用）、异常表、隐式空指针异常表。

## 7. 入口偏移定址：verified/osr 双入口

机器码写完，`install()`（**output.cpp:3302**）先把入口偏移定下来：

```cpp
// output.cpp:3331-3346
if (C->is_osr_compilation()) {
  _code_offsets.set_value(CodeOffsets::Verified_Entry, 0);          // OSR 无 verified 入口
  _code_offsets.set_value(CodeOffsets::OSR_Entry, _first_block_size);
} else {
  _code_offsets.set_value(CodeOffsets::Verified_Entry, _first_block_size);
  // Verified_Inline_Entry / Verified_Inline_Entry_RO / Entry 缺失则回填 _first_block_size
  ...
  _code_offsets.set_value(CodeOffsets::OSR_Entry, 0);
}
```

**双入口设计**：
- `Verified_Entry`：常规入口（方法表/虚表里的目标），调用方已验证 receiver 类型
- `OSR_Entry`：栈上替换入口——方法在解释器里跑到一半（循环），从 `OSR_Entry` 直接进编译码，栈帧现场接上（`_first_block_size` 是第一个基本块的位置）
- OSR 编译没有 verified 入口（没人从方法表进来），普通编译没有 OSR 入口（除非特意开）

然后 :3348 把这一切交给 `C->env()->register_method(...)`：传入 code_buffer、入口偏移、frame_size、OopMapSet、异常表、隐式异常表、编译器、一堆 flag。

## 8. 安装门禁：register_method 的六道检查

`ciEnv::register_method`（**ciEnv.cpp:977**）是编译产物进入 JVM 的**大门**，六道检查缺一不可：

```cpp
// ciEnv.cpp:998-1017
if (method->get_method_counters(THREAD) == nullptr) {   // ① 方法计数器必须存在
  record_failure("can't create method counters");
  code_buffer->free_blob();
  return;
}
CodeCache::gc_on_allocation();                          // ② 空间不足先 GC（codeCache.cpp:882）
MutexLocker locker(THREAD, MethodCompileQueue_lock);    // ③ 编译队列锁
MutexLocker ml(Compile_lock);                           // ④ Compile_lock
NoSafepointVerifier nsv;
// :1013-1015 注释：防止 InstanceKlass::add_to_hierarchy 运行并
// 在我们安装完之前使依赖失效——不允许安全点，否则类重定义可能插入
```

```cpp
// ciEnv.cpp:1020-1046
if (!failing() && jvmti_state_changed())                // ⑤ 外部状态检查
  record_failure("Jvmti state change invalidated dependencies");
if (!failing() &&
    ((!dtrace_method_probes() && DTraceMethodProbes) ||
     (!dtrace_alloc_probes() && DTraceAllocProbes)))
  record_failure("DTrace flags change invalidated dependencies");
...
dependencies()->encode_content_bytes();                 // ⑥ 依赖编码成字节
validate_compile_task_dependencies(target);              //    并立刻校验
```

**为什么这么严？** 编译期间（可能几十毫秒）外部世界没停：新类可能被加载、类层次可能变化、JVMTI 可能挂上断点。第四站 `assert_unique_concrete_method` 记的依赖是"编译时的快照假设"，安装这一刻必须**验证假设仍成立**，否则装上去就是错的代码。:1049-1060 失败路径还顺手 `inc_decompile_count()`——把"编译被作废"记进方法档案。

## 9. nmethod 创建：new_nmethod 的空间账本

门禁通过，`nmethod::new_nmethod`（**nmethod.cpp:1090**）开工：

```cpp
// nmethod.cpp:1106-1138
code_buffer->finalize_oop_references(method);
int nmethod_size = CodeBlob::allocation_size(code_buffer, sizeof(nmethod));
int immutable_data_size =
      adjust_pcs_size(debug_info->pcs_size())
    + align_up((int)dependencies->size_in_bytes(), oopSize)   // 依赖表
    + align_up(handler_table->size_in_bytes(), oopSize)        // 异常表
    + align_up(nul_chk_table->size_in_bytes(), oopSize)        // 隐式异常表
    + align_up(debug_info->data_size(), oopSize);              // 调试信息
...
{
  MutexLocker mu(CodeCache_lock, Mutex::_no_safepoint_check_flag);
  nm = new (nmethod_size, comp_level)                         // placement new
  nmethod(method(), compiler->type(), nmethod_size, ...);
```

**空间账本**：
- **nmethod_size**：代码本体 + nmethod 头，分配在 **CodeCache** 里（`new (nmethod_size, comp_level)` 的 placement new）
- **immutable_data**：PC 描述、依赖表、异常表、隐式异常表、调试数据——不可变数据单独从 **C heap** 分配（:1118-1127），可以跨 GC 共享/复用（引用计数 `ImmutableDataRefCountSize`）
- **mutable_data**：重定位 + metadata

构造（:1231 附近）把 CodeBuffer 里的东西倒进 nmethod：`code_buffer->copy_code_and_locs_to(this)`、`copy_values_to(this)`，然后 `post_init()`（**nmethod.cpp:1211**）：

```cpp
// nmethod.cpp:1211-1228  post_init
clear_unloading_state();
finalize_relocations();                                  // 重定位收尾
ICache::invalidate_range(code_begin(), code_size());     // 刷新指令缓存（x86 上为一致性）
Universe::heap()->register_nmethod(this);                // GC 侧登记（跨代引用扫描）
CodeCache::commit(this);                                 // 提交进 CodeCache（codeCache.cpp:716）
```

## 10. 依赖登记：按类挂载的"把柄"

new_nmethod 末尾（**nmethod.cpp:1140-1162**）把依赖**挂到依赖类上**：

```cpp
// nmethod.cpp:1141-1162
// 注释：为了类加载时依赖检查快，把 nmethod 依赖记在它依赖的类上。
// 这样依赖检查代码只需沿着被加载类上方的类层次走，只查依赖这些类的 nmethod；
// 慢方法是检查每个 nmethod 的依赖，随编译方法数线性增长，应用类多时太慢。
for (Dependencies::DepStream deps(nm); deps.next(); ) {
  if (deps.type() == Dependencies::call_site_target_value) {
    oop call_site = deps.argument_oop(0);
    MethodHandles::add_dependent_nmethod(call_site, nm);   // CallSite 依赖挂 CallSite
  } else {
    InstanceKlass* ik = deps.context_type();
    if (ik == nullptr) continue;   // ignore things like evol_method
    ik->add_dependent_nmethod(nm); // 类依赖挂 InstanceKlass
  }
}
```

落到 `DependencyContext`（**dependencyContext.cpp:92**）：

```cpp
// dependencyContext.cpp:92-128（节选）
void DependencyContext::add_dependent_nmethod(nmethod* nm) {
  assert_lock_strong(CodeCache_lock);
  assert(nm->is_not_installed(), "Precondition: new nmethod");
  // 不变量：新 nmethod 要么不在链表里，要么已在链表头——
  // 因此可以跳过链表扫描，只需检查头节点
  nmethodBucket* head = AtomicAccess::load(_dependency_context_addr);
  if (head != nullptr && nm == head->get_nmethod()) return;
  nmethodBucket* new_head = new nmethodBucket(nm, nullptr);
  for (;;) {
    new_head->set_next(head);
    if (AtomicAccess::cmpxchg(_dependency_context_addr, head, new_head) == head) break;
    head = AtomicAccess::load(_dependency_context_addr);
  }
```

**为什么按类挂载？** 类加载时检查依赖（`InstanceKlass::add_to_hierarchy` 等）只需要沿着新类的父类链走，**只查挂在这些类上的 nmethod**——从"扫全部 nmethod"变成"查相关类"，把线性变常数。第四站 CHA 假设 `"B.m 是 A.m 的唯一实现"` 就挂在这——新类 D 加载覆盖 m() 时，D 的类层次检查立刻发现 A 上挂着这个依赖，触发 nmethod 失效。

## 11. 挂牌上岗：make_in_use 与 Method::set_code

依赖挂完，回 `register_method` 收尾（**ciEnv.cpp:1084-1126**）：

```cpp
// ciEnv.cpp:1087-1112
if (entry_bci == InvocationEntryBci) {
  if (TieredCompilation) {
    nmethod* old = method->code();
    if (old != nullptr) old->make_not_used();   // :1097 旧编译版本退役（NOT_USED 原因）
  }
  MutexLocker ml(NMethodState_lock, Mutex::_no_safepoint_check_flag);
  if (nm->make_in_use()) {                       // :1110 状态 in_use
    method->set_code(method, nm);                // :1111 挂牌！
  }
} else {
  ...
  if (nm->make_in_use()) {
    method->method_holder()->add_osr_nmethod(nm); // :1123 OSR 版本挂到 holder
  }
}
```

- `make_in_use()`（**nmethod.hpp:708**）= `try_transition(in_use)`——状态从 `not_installed` 推到 `in_use`，**这一刻编译码才允许被执行**
- 普通编译挂到 `Method::_code`；OSR 编译挂到 `method_holder()->add_osr_nmethod`（按 entry_bci 索引）

真正的挂牌是 `Method::set_code`（**method.cpp:1441**）：

```cpp
// method.cpp:1441-1464
void Method::set_code(const methodHandle& mh, nmethod *code) {
  assert_lock_strong(NMethodState_lock);
  guarantee(mh->adapter() != nullptr, "Adapter blob must already exist!");
  // 注释：写顺序必须如此——解释器会直接跳 from_interpreted_entry，
  // 它跳到 i2c adapter，adapter 再跳到 _from_compiled_entry。
  mh->_code = code;                        // :1451 先挂 code（允许编译码执行）
  ...
  OrderAccess::storestore();               // :1460 写屏障
  mh->_from_compiled_entry = code->verified_entry_point();               // :1461
  mh->_from_compiled_inline_entry = code->verified_inline_entry_point();
  mh->_from_compiled_inline_ro_entry = code->verified_inline_ro_entry_point();
  OrderAccess::storestore();
```

**这是五站闭环的最后一颗螺丝**：解释器每次进方法跳 `from_interpreted_entry`（03 站 `jump_from_interpreted` 的入口）→ i2c adapter → `_from_compiled_entry` → nmethod 的 verified entry point。顺序用 storestore 屏障保证——`_code` 先可见，入口指针后可见，避免解释器跳到半初始化的编译码。

`post_compiled_method`（:1132）最后触发 JVMTI `CompiledMethodLoad` 事件，调试器看到新代码。

## 12. 赌输撤回：make_not_entrant 去优化

第四站 `assert_unique_concrete_method` 的依赖被破坏时（新类加载覆写了方法），谁发现谁调用 `make_not_entrant`（**nmethod.cpp:2215**）：

```cpp
// nmethod.cpp:2215-2279（节选）
bool nmethod::make_not_entrant(InvalidationReason invalidation_reason) {
  NoSafepointVerifier nsv;
  if (is_unloading()) return false;                 // GC 正在卸载，交给 GC
  if (AtomicAccess::load(&_state) == not_entrant)   // 幂等：已是终态
    return false;
  {
    ConditionalMutexLocker ml(NMethodState_lock, ...);
    if (is_osr_method()) {
      invalidate_osr_method();                      // :2249 OSR：直接废掉 OSR 入口
    } else {
      BarrierSet::barrier_set()->barrier_set_nmethod()
              ->make_not_entrant(this);             // :2253 常规：patch 入口
    }
    if (update_recompile_counts()) {
      inc_decompile_count();                        // :2258 记反编译次数
    }
    ...
    bool success = try_transition(not_entrant);     // :2270 状态 → not_entrant
    log_state_change(invalidation_reason);
    unlink_from_method();                           // :2277 从 Method 摘除
  }
  return true;
}
```

**四个动作，一个目的——让"新调用"再也进不了这段代码**：
1. **入口 patch**（:2253）：nmethod 入口屏障（BarrierSetNMethod）把入口改写成跳去解释器——已执行的旧帧继续跑完（`not_entrant` 语义：*activations may still exist*，nmethod.hpp:693），新调用进不来
2. **OSR 特例**（:2249）：OSR 版本直接废掉 OSR 入口
3. **反编译计数**（:2258）：`inc_decompile_count`——这正是第四站 step13 `too_many_traps_or_recompiles` 读的计数器，撤太多次编译器就放弃这条优化路线
4. **摘除**（:2277）：`unlink_from_method`，`Method::_code` 不再指向它

失效原因枚举（**nmethod.hpp:535-561**）里有 UNCOMMON_TRAP（:549）、ZOMBIE（:553）、RELOCATED（:555）等——第四站守卫菱形 miss 走 `uncommon_trap` 就是 UNCOMMON_TRAP 原因。

## 13. 回收与状态机：从 not_entrant 到 purge

**状态机**（**nmethod.hpp:690-694**）：

```cpp
// nmethod.hpp:690-694
enum : signed char { not_installed = -1, // 构造中，只有构造者能推进状态
                     in_use        = 0,  // 可执行
                     not_entrant   = 1   // 标记去优化，但旧激活帧可能仍存在
};
bool is_in_use()  const { return _state <= in_use; }   // in_use 或更早
```

`not_entrant` 之后是**安全回收**两步：

```cpp
// nmethod.cpp:2293-2318  unlink（GC 卸载时调用）
void nmethod::unlink() {
  if (is_unlinked()) return;
  flush_dependencies();                    // :2299 从所有依赖上下文摘除自己
  unlink_from_method();
  if (is_osr_method()) invalidate_osr_method();
  post_compiled_method_unload();           // :2312 JVMTI 卸载事件
  ClassUnloadingContext::context()->register_unlinked_nmethod(this);  // :2317 排队等 flush
}

// nmethod.cpp:2320-2334  purge（彻底释放）
void nmethod::purge(bool unregister_nmethod) {
  MutexLocker ml(CodeCache_lock, ...);
  Events::log_nmethod_flush(Thread::current(), "flushing %s nmethod ...", ...);
  ...  // 释放 CodeCache 空间
}
```

- **unlink**：从依赖表摘除（倒过来执行第 10 节的登记）、从 Method 摘除、发卸载事件——**不再被任何引用找到**
- **purge**：物理释放 CodeCache 内存
- 中间隔着 GC 的卸载握手（unloading handshake），保证没有线程还在这段代码里执行

## 14. 五站闭环：一条 invokevirtual 的一生

五站拼起来，一条 `invokevirtual` 从字节码到 CPU 的完整一生：

```
字节码：invokevirtual #12 ──────────────────────────────────────────┐
                                                                      │ 第一次执行
01 linkResolver  符号解析：常量池条目 → Method*（LinkResolver）       │ 冷路径
02 klassVtable    建表：vtable/itable 就位，槽位 = 方法入口            │ 初始化
03 templateTable 解释器：1 条 movptr 查表 → 跳转（profile 写 MDO）     │ 热路径（快）
                                                                      │ 阈值触发 C2
04 doCall/bytecodeInfo  C2 决策：赌直接调用/内联（四连问+决策总闸）    │ 编译线程
05 codegen/nmethod 兑现赌注：
     Code_Gen（Matcher→Chaitin→PhaseOutput 出机器码）
     → new_nmethod + 依赖登记
     → make_in_use + Method::set_code（_from_compiled_entry 指向新码）
     → 下一次调用：解释器 → i2c adapter → 编译码 ←───────────────┘
     赌输：依赖破坏 → make_not_entrant → 入口 patch → 回解释器
            → inc_decompile_count → 重编译（或放弃）
```

- **01-03 站**：解释器怎么"找到方法"（解析、建表、查表）
- **04 站**：C2 怎么"赌方法"（去虚化/内联决策）
- **05 站**：赌注怎么"兑现与撤回"（机器码 + nmethod + 失效）

四站呼应关系：03 站 `jump_from_interpreted` 的落点 = 05 站 `_from_compiled_entry`（method.cpp:1461）；04 站 `inc_decompile_count` 的读者 = 05 站 `make_not_entrant` 的写者（nmethod.cpp:2258）；04 站 `assert_unique_concrete_method` 的依赖 = 05 站按类挂载 + `make_not_entrant` 触发（nmethod.cpp:1149 / dependencyContext.cpp:92）。

## 15. 行号速查表

| 文件 | 行号 | 内容 |
|------|------|------|
| opto/c2compiler.cpp | 125 | C2Compiler::compile_method（驱动 while 循环） |
| opto/c2compiler.cpp | 153 / 159 | 降级重试：关 SubsumeLoads / 关 DoEscapeAnalysis |
| opto/compile.cpp | 659 / 887 / 946 | Compile 构造 → Optimize() → Code_Gen() |
| opto/compile.cpp | 3790 | Compile::Code_Gen |
| opto/compile.cpp | 3805 / 3809 | Matcher 构造 / matcher.match() |
| opto/compile.cpp | 3827 / 3834 | PhaseCFG / do_global_code_motion |
| opto/compile.cpp | 3847 / 3854 | PhaseChaitin / Register_Allocate |
| opto/compile.cpp | 3870 / 3883 / 3891 | remove_empty_blocks+布局 / PhasePeephole / postalloc_expand |
| opto/compile.cpp | 3907 / 3910 | PhaseOutput / output.install() |
| opto/matcher.cpp | 216 | Matcher::match |
| opto/chaitin.cpp | 356 / 380 / 383 / 393 | Register_Allocate / PhaseLive / PhaseIFG / de_ssa |
| opto/output.cpp | 210 / 253 | PhaseOutput 构造 / Output() |
| opto/output.cpp | 270-275 / 294-297 / 311 / 1883 | prolog / MachUEPNode / epilog / Deopt handler |
| opto/output.cpp | 3302 / 3316 | install / install_code |
| opto/output.cpp | 3331-3346 | 入口偏移（Verified_Entry / OSR_Entry） |
| ci/ciEnv.cpp | 977 | ciEnv::register_method |
| ci/ciEnv.cpp | 998 / 1008 / 1011-1016 | 计数器检查 / CodeCache GC / 双锁+NoSafepoint |
| ci/ciEnv.cpp | 1020-1034 / 1043 / 1046 | 失效检查 / 依赖编码 / 依赖校验 |
| ci/ciEnv.cpp | 1070 | nmethod::new_nmethod |
| ci/ciEnv.cpp | 1097 / 1110 / 1111 | old->make_not_used / make_in_use / method->set_code |
| ci/ciEnv.cpp | 1123 / 1132 | add_osr_nmethod / post_compiled_method |
| code/nmethod.cpp | 1090 / 1106 / 1109-1127 | new_nmethod / finalize_oop_references / 空间账本 |
| code/nmethod.cpp | 1132-1138 | CodeCache_lock + placement new |
| code/nmethod.cpp | 1149-1160 | 依赖登记（DepStream → ik/CallSite） |
| code/nmethod.cpp | 1211-1228 | post_init（reloc / ICache / GC / CodeCache::commit） |
| code/nmethod.cpp | 2215 / 2225 / 2249 / 2253 | make_not_entrant / 幂等 / OSR 废入口 / 入口 patch |
| code/nmethod.cpp | 2256-2259 / 2270 / 2277 | inc_decompile_count / try_transition(not_entrant) / unlink_from_method |
| code/nmethod.cpp | 2293 / 2299 / 2317 | unlink / flush_dependencies / register_unlinked_nmethod |
| code/nmethod.cpp | 2320 | purge（物理释放） |
| code/nmethod.hpp | 690-694 | 状态机 not_installed=-1 / in_use=0 / not_entrant=1 |
| code/nmethod.hpp | 549 / 553 | UNCOMMON_TRAP / ZOMBIE 失效原因 |
| code/dependencyContext.cpp | 92 / 110-128 | add_dependent_nmethod（头插 + CAS） |
| code/codeCache.cpp | 716 / 882 | commit / gc_on_allocation |
| oops/method.cpp | 1441-1464 | Method::set_code（_code → storestore → _from_compiled_entry） |
| oops/instanceKlass.cpp | 2930-2932 | InstanceKlass::add_dependent_nmethod |
