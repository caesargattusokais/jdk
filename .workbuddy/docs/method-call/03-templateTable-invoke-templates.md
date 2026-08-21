# 方法调用全链路 · 第三站：解释器 invoke 模板（templateTable）

> **快速概览**：第一站 `linkResolver` 解决了"符号 → Method*"的**解析**问题，第二站 `klassVtable` 解决了"分派表怎么建"的**构建**问题。本站是**执行**问题——解释器拿到一条 `invokevirtual` 字节码后，怎么在几纳秒内完成寻址、查表、跳转，真正把方法调起来。答案藏在 `cpu/x86/templateTable_x86.cpp` 的四个模板里：**热路径寻址（3 条汇编）→ 准备调用（2 件事）→ 分派（1 次查表）→ 最后一跳（1 条 jmp）**。
>
> **关联站**：01（linkResolver 冷路径写缓存）→ 02（vtable/itable 构建）→ **03（本站在热路径读缓存、查表、跳转）** → 后续 C2 `doCall`（去虚化/内联）。

---

## TOC

- [一、模板是什么：解释器为什么快](#一模板是什么解释器为什么快)
- [二、四个 invoke 入口总览](#二四个-invoke-入口总览)
- [三、热路径第一步：load_method_entry 寻址](#三热路径第一步load_method_entry-寻址)
- [四、已解析还是未解析：冷热路径的岔路口](#四已解析还是未解析冷热路径的岔路口)
- [五、prepare_invoke：调用前的最后准备](#五prepare_invoke调用前的最后准备)
- [六、invokevirtual_helper：final 直接跳 vs vtable 查表](#六invokevirtual_helperfinal-直接跳-vs-vtable-查表)
- [七、lookup_virtual_method：一条 movptr 的多态](#七lookup_virtual_method一条-movptr-的多态)
- [八、invokeinterface 三分支：Object / private / 常规](#八invokeinterface-三分支object--private--常规)
- [九、lookup_interface_method：线性扫描的汇编形态](#九lookup_interface_method线性扫描的汇编形态)
- [十、最后一跳：jump_from_interpreted](#十最后一跳jump_from_interpreted)
- [十一、三站闭环：冷路径写缓存、热路径读缓存](#十一三站闭环冷路径写缓存热路径读缓存)
- [十二、行号速查表](#十二行号速查表)

---

## 一、模板是什么：解释器为什么快

解释器逐条执行字节码，但**每条字节码的"翻译"只做一次**——class 文件加载时，解释器生成器把每条字节码编译成一段机器码（叫 **codelet**），执行时 CPU 直接跑这段机器码，不用反复 decode。

`templateTable_x86.cpp` 就是这些模板的 x86 实现。`invoke*` 家族有四个模板入口：

| 字节码 | 模板函数 | 行号 |
|---|---|---|
| `invokevirtual` | `TemplateTable::invokevirtual` | :3479 |
| `invokespecial` | `TemplateTable::invokespecial` | :3496 |
| `invokestatic` | `TemplateTable::invokestatic` | :3515 |
| `invokeinterface` | `TemplateTable::invokeinterface` | :3539 |

> 💡 **为什么叫模板（template）**：像盖章一样，一类字节码盖出一个机器码模板。所有 `invokevirtual` 共享同一段 codelet，区别只在运行时寄存器里的值。

## 二、四个 invoke 入口总览

四个入口结构高度统一，都是**三段式**：

```
① load_resolved_method_entry_*  从 ResolvedMethodEntry 读 flags + Method*/index/klass
② prepare_invoke                取 receiver（非 static）+ 压解释器返回地址
③ 分派跳转                       final 直接跳 / vtable 查表 / itable 扫描 → jump_from_interpreted
```

例如 `invokevirtual`（:3479）只有 3 行核心调用：

```cpp
load_resolved_method_entry_virtual(rcx,  // ResolvedMethodEntry*
                                   rbx,  // Method 或 itable index
                                   rdx); // Flags
prepare_invoke(rcx, rcx, rdx);
invokevirtual_helper(rbx, rcx, rdx);
```

> 💡 **寄存器分工**（x86 解释器调用约定）：`rbx` 必须是 Method*（解释器约定），`rcx` 是 receiver，`rdx` 是 flags。

**关键概念：ResolvedMethodEntry（RME）**——JDK 28 中取代老 ConstantPoolCacheEntry 的调用缓存项（`oops/resolvedMethodEntry.hpp:68`）：

```cpp
class ResolvedMethodEntry {
  Method* _method;                    // 非虚调用 / final 方法的 Method*
  union {
    InstanceKlass* _interface_klass;  // interface / static 用
    u2 _resolved_references_index;    // invokehandle 的 appendix 索引
    u2 _table_index;                  // vtable/itable index（virtual/interface 用）
  } _entry_specific;
  u2 _cpool_index;                    // 常量池索引（回源用）
  u2 _number_of_parameters;           // 参数个数（取 receiver 用）
  u1 _tos_state;                      // 栈顶类型（决定返回地址表项）
  u1 _flags;                          // 6 个位标志
  u1 _bytecode1, _bytecode2;          // 已解析的字节码（防"双字节码共享"误判）
};
```

**flags 六位**（resolvedMethodEntry.hpp:119-126）：

| 位 | 名称 | 含义 |
|---|---|---|
| 0 | `is_vfinal` | 方法已是 Method*（final/private），不是 index |
| 1 | `is_final` | final 方法 |
| 2 | `is_forced_virtual` | invokeinterface 调 Object 方法 → 强制走 invokevirtual |
| 3 | `has_appendix` | invokehandle 有 appendix 参数 |
| 4 | `has_local_signature` | 本地签名 |
| 5 | `has_resolved_ref` | 有 resolved references 索引 |

> 💡 **为什么叫"双字节码"**：invokevirtual 和 invokespecial 可能共享同一常量池条目（见 hpp:60 注释），所以 `_bytecode1` 存 f1 字节码、`_bytecode2` 存 f2 字节码，各自记录解析状态。

## 三、热路径第一步：load_method_entry 寻址

`load_resolved_method_entry_*` 三件套的第一步都是 `resolve_cache_and_index_for_method`（:2301），它先调 `load_method_entry`（interp_masm_x86.cpp:1855）**从字节码里的 u2 索引拿到 RME 指针**：

```cpp
void InterpreterMacroAssembler::load_method_entry(Register cache, Register index, int bcp_offset) {
  movptr(cache, Address(rbp, frame::interpreter_frame_cache_offset * wordSize)); // ① 帧里取 ConstantPoolCache 基址
  get_cache_index_at_bcp(index, bcp_offset, sizeof(u2));                          // ② 从字节码流读 u2 index
  movptr(cache, Address(cache, ConstantPoolCache::method_entries_offset()));      // ③ 定位 method_entries 数组
  imull(index, index, sizeof(ResolvedMethodEntry));                               // ④ index × entry 大小
  lea(cache, Address(cache, index, Address::times_1, Array<ResolvedMethodEntry>::base_offset_in_bytes())); // ⑤ 基址 + 偏移 → entry 指针
}
```

> 💡 **这条寻址链是热的**：解释器帧里有现成的 CPCache 指针（`rbp + cache_offset`），字节码里的 u2 index 是编译期就写死的——5 条汇编全是地址计算，没有任何内存查找或条件分支。**多态的第一个成本 ≈ 0**。

## 四、已解析还是未解析：冷热路径的岔路口

拿到 RME 指针后，`resolve_cache_and_index_for_method`（:2301）**比对 RME 里的 `_bytecode1/_bytecode2` 与当前操作码**：

```cpp
load_method_entry(cache, index);                       // 热路径入口（上面 5 条汇编）
// f1_byte → 读 bytecode1_offset；f2_byte → 读 bytecode2_offset
cmpl(temp, code);                                      // 已解析成这个字节码了吗？
jcc(Assembler::equal, L_done);                         // ✅ 相等 → 热路径直接走
// ❌ 不相等 → 首次执行，走冷路径：
address entry = CAST_FROM_FN_PTR(address, InterpreterRuntime::resolve_from_cache);
call_VM_preemptable(noreg, entry, temp);               // 调回 VM → linkResolver（01 站）
load_method_entry(cache, index);                       // 解析完成，重新加载 entry
bind(L_done);
```

- **热路径**：相等 → `L_done`，一条条件跳转跳过，**几纳秒**。
- **冷路径**：不相等 → `resolve_from_cache` → 内部走 01 站的 `resolve_invoke` 全链路 → 结果写回 RME（`_method`/`_table_index`/`_flags`/`_bytecode1/2` 全部填好）→ 重新加载。

> 💡 **invokestatic 特例（:2327-2336）**：静态调用前多一道 **clinit_barrier**——取方法所属类，检查类是否已初始化，没初始化先初始化（呼应 keywords 05 篇 class init 状态机）。

## 五、prepare_invoke：调用前的最后准备

分派前的两件事（:3394）：

```cpp
void TemplateTable::prepare_invoke(Register cache, Register recv, Register flags) {
  const bool load_receiver = (code != _invokestatic) && (code != _invokedynamic);
  save_bcp();
  // ① 取 receiver
  if (load_receiver) {
    load_unsigned_short(recv, Address(cache, ResolvedMethodEntry::num_parameters_offset()));
    Address recv_addr = argument_address(recv, no_return_pc_pushed_yet + receiver_is_at_end);
    movptr(recv, recv_addr);   // 参数数量回退一格 = receiver 在栈上的位置
    verify_oop(recv);
  }
  // ② 压"解释器返回地址"
  const address table_addr = (address) Interpreter::invoke_return_entry_table_for(code);
  lea(rscratch1, table_addr);
  movptr(flags, Address(rscratch1, flags, Address::times_ptr)); // 按 tos_type 查表
  push(flags);
  restore_bcp();
}
```

> 💡 **解释器返回地址不是真正的返回地址**：它是一段"回到解释器分发循环"的代码入口（`invoke_return_entry_table` 按 `tos_state` 分成多张表，因为返回时要按返回类型恢复栈顶状态）。压栈后，被调方法返回时 `ret` 会落到这段代码，继续解释下一条字节码。
>
> 💡 **invokestatic 不取 receiver**（`load_receiver=false`），`invokeinterface` 也要取 receiver——所以接口调用的 null 检查发生在模板里。

## 六、invokevirtual_helper：final 直接跳 vs vtable 查表

分派核心（:3435），**一条汇编判断走哪条路**：

```cpp
void TemplateTable::invokevirtual_helper(Register index, Register recv, Register flags) {
  // 测试 is_vfinal 位
  movl(rax, flags);
  andl(rax, (1 << ResolvedMethodEntry::is_vfinal_shift));
  jcc(Assembler::zero, notFinal);              // is_vfinal=0 → 多态，走查表

  // ✅ is_vfinal=1：index 寄存器里直接就是 Method*（final/private 方法）
  null_check(recv);                            // final 方法也要 null 检查（NPE 语义）
  profile_final_call(rax);
  jump_from_interpreted(method, rax);          // 直接跳！

  bind(notFinal);                              // ❌ 多态路径：
  load_klass(rax, recv, rscratch1);            // ① 取 receiver 的实际类
  profile_virtual_call(rax, rlocals);          // ② 方法内联缓存计数（C2 内联决策依据）
  lookup_virtual_method(rax, index, method);   // ③ vtable 查表（见下节）
  jump_from_interpreted(method, rdx);          // ④ 跳
}
```

> 💡 **这就是"final 方法可内联"的汇编依据**：final/private 方法在解析期就被判定 `is_vfinal`，RME 里存的是 **Method\* 而不是 index**——运行时**根本不需要查表**。C2 看到这种直接跳转形态，才敢放心内联（呼应 08 篇 ciMethod.hpp:353）。

## 七、lookup_virtual_method：一条 movptr 的多态

vtable 查表（macroAssembler_x86.cpp:4035）——**整个多态分派的核心只有一条汇编**：

```cpp
void MacroAssembler::lookup_virtual_method(Register recv_klass,
                                           RegisterOrConstant vtable_index,
                                           Register method_result) {
  const ByteSize base = Klass::vtable_start_offset();
  Address vtable_entry_addr(recv_klass,
                            vtable_index, Address::times_ptr,   // recv_klass + index * 8
                            base + vtableEntry::method_offset());
  movptr(method_result, vtable_entry_addr);   // ← 多态的全部成本
}
```

**为什么成立**：第二站讲过 vtable 紧跟 Klass 头（klass.inline.hpp:112），每个 `vtableEntry` 恰好一个指针宽（klassVtable.hpp:194），所以 `index × 8` 就是天然寻址。

> 💡 **多态的真实成本**：`recv_klass + index*8 + offset` 一次内存读。**这就是"虚方法调用≈零成本"的真相**——不是没有查表，而是查表被压成了一条 movptr。

## 八、invokeinterface 三分支：Object / private / 常规

invokeinterface（:3539）比 virtual 复杂——同一入口处理三种形态，用 flags 分流：

```cpp
// ① is_forced_virtual：调的是 java.lang.Object 的方法（如 equals/hashCode）
testl(rlocals, (1 << ResolvedMethodEntry::is_forced_virtual_shift));
jcc(zero, notObjectMethod);
invokevirtual_helper(rbx, rcx, rdx);   // 强制走 invokevirtual（vtable 查表）

bind(notObjectMethod);
// ② is_vfinal：private 接口方法
testl(rlocals, (1 << ResolvedMethodEntry::is_vfinal_shift));
jcc(zero, notVFinal);
load_klass(rlocals, rcx, rscratch1);                 // 接收者类型
check_klass_subtype(rlocals, rax, rbcp, subtype);    // 必须实现该接口
// subtype 检查失败 → no_such_interface（ICCE）
jump_from_interpreted(rbx, rdx);                     // 直接跳（Method* 已在 rbx）

bind(notVFinal);
// ③ 常规接口方法：itable 扫描（见下节）
load_klass(rdx, rcx, rscratch1);                     // 接收者实际类
lookup_interface_method(rdx, rax, noreg, rbcp, rlocals, no_such_interface, false); // 第一遍：只做 subtype 检查
load_method_holder(rax, rbx);                        // 从 Method 拿声明接口
movl(rbx, Address(rbx, Method::itable_index_offset()));
subl(rbx, Method::itable_index_max); negl(rbx);      // 恢复真实 itable index
lookup_interface_method(rlocals, rax, rbx, rbx, rbcp, no_such_interface); // 第二遍：真正拿方法
// rbx 为 null → no_such_method（AbstractMethodError）；否则 jump_from_interpreted
```

> 💡 **为什么 Object 方法要特殊处理**：`invokeinterface` 调 `equals` 这种 Object 方法时，接收者类可能根本不实现声明接口的 itable 槽——按接口语义走 itable 会找不到。VM 在解析期发现目标方法属于 Object，就置 `is_forced_virtual`，运行时强制走 vtable。
>
> 💡 **为什么扫两遍**：第一遍（`return_method=false`）只确认"接收者确实实现了该接口"（失败 → ICCE）；第二遍才带 itable index 真正取方法（失败 → AME）。subtype 检查用了 06 篇讲过的 `check_klass_subtype_fast_path`（:4058 super_check_offset 快路径）。

## 九、lookup_interface_method：线性扫描的汇编形态

itable 查表（macroAssembler_x86.cpp:3841）——**第二站 C++ 版 `method_at_itable_or_null` 的汇编对应物**，注释里直接写着 C 循环：

```cpp
// for (scan = klass->itable(); scan->interface() != nullptr; scan += scan_step) {
//   if (scan->interface() == intf) {
//     result = (klass + scan->offset() + itable_index);
//   }
// }
movl(scan_temp, Address(recv_klass, Klass::vtable_length_offset()));  // vtable 长度
lea(scan_temp, Address(recv_klass, scan_temp, times_vte_scale, vtable_base)); // itable 起点（vtable 尾）
// 剥皮循环（peel 1/0）：
//   读 itableOffsetEntry.interface → cmp intf
//   相等 → found_method；不等 → 查下一项；interface 为 null → L_no_such_interface
bind(found_method);
movl(scan_temp, Address(scan_temp, itableOffsetEntry::offset_offset())); // 拿 offset
movptr(method_result, Address(recv_klass, scan_temp, Address::times_1)); // klass + offset + index*8 → Method*
```

> 💡 **为什么 itable 用扫描而不是直接寻址**：vtable 是"每类一份、从 0 编号"，天然可以 `index×8`；itable 是"接口的槽位是**编译期**定的（itable_index），但每个类实现的**接口集合不同**"——必须先找到"接收者类里的这个接口的 offset 表"，再做二次寻址。扫描的代价换来的是**多接口继承的灵活性**。
>
> 💡 **终止哨兵**：扫描到 `interface == null` 的哨兵项 = 接收者没实现该接口 → `no_such_interface` → ICCE。

## 十、最后一跳：jump_from_interpreted

拿到 Method* 后，一切准备就绪，跳进被调方法（interp_masm_x86.cpp:715）：

```cpp
void InterpreterMacroAssembler::jump_from_interpreted(Register method, Register temp) {
  prepare_to_jump_from_interpreted();                       // 规范化解释器寄存器（rbcp/rlocals 等）
  if (JvmtiExport::can_post_interpreter_events()) {
    // JVMTI 单步等事件 → 强制走纯解释器入口
    jmp(Address(method, Method::interpreter_entry_offset()));
  }
  jmp(Address(method, Method::from_interpreted_offset()));  // ← 常规路径
}
```

> 💡 **Method 对象里存着入口指针**：`Method::from_interpreted_offset()` 是 Method 结构里的一个字段——方法第一次被解释执行时填好"解释器入口"，之后每次调用都是**一条 jmp**。jmp 之后，被调方法的 codelet 开始跑；它 `ret` 时回到 prepare_invoke 压的解释器返回地址，继续解释下一条。

## 十一、三站闭环：冷路径写缓存、热路径读缓存

三站串成一条完整的"方法调用循环"：

```
                ┌──────────── 冷路径（只在首次执行）────────────┐
                │                                             │
   invokevirtual │   resolve_from_cache(:2343)                │
   ↓             │     → LinkResolver::resolve_invoke(01:1715)│
 [热路径寻址]     │     → 七步解析 + runtime 分派               │
 :1855 取RME     │     → CallInfo::set_* 写回 RME             │
                └──────────────┬──────────────────────────────┘
                               │ 写：_method/_table_index/_flags/_bytecode1/2
                               ▼
  已解析？─ 是 ─→ prepare_invoke(:3394) 取receiver+压返回地址
   :2324 比对      │
                   ▼
         invokevirtual_helper(:3435)
           ├─ is_vfinal → 直接 jump_from_interpreted(:715) ──→ 被调方法 codelet
           └─ 否则 → load_klass → lookup_virtual_method(:4035)
                         一条 movptr 读 vtable → jump ────────→ 同上
```

- **01 站**管"怎么解析"（冷路径，写缓存）
- **02 站**管"表怎么建"（vtable/itable 的内存与槽位）
- **03 站（本站）**管"怎么用"（热路径，读缓存、查表、跳转）

> 💡 **性能全景**：一次多态 invokevirtual = 5 条地址计算 + 1 次比较 + 2 次内存读（flags + vtable 项）+ 1 条 jmp。**解释器的"慢"不在这条链，而在没有 JIT 的反复 decode 和类型检查**——这正是下一站 C2 `doCall` 要去虚化/内联的原因。

## 十二、行号速查表

| 内容 | 文件:行号 |
|---|---|
| invokevirtual 模板入口 | templateTable_x86.cpp:3479 |
| invokespecial 模板入口 | templateTable_x86.cpp:3496 |
| invokestatic 模板入口 | templateTable_x86.cpp:3515 |
| invokeinterface 模板入口 | templateTable_x86.cpp:3539 |
| load_resolved_method_entry_special_or_static | templateTable_x86.cpp:2489 |
| load_resolved_method_entry_interface | templateTable_x86.cpp:2533 |
| load_resolved_method_entry_virtual | templateTable_x86.cpp:2569 |
| resolve_cache_and_index_for_method（冷热分岔） | templateTable_x86.cpp:2301 |
| prepare_invoke（取 receiver + 压返回地址） | templateTable_x86.cpp:3394 |
| invokevirtual_helper（vfinal vs 查表） | templateTable_x86.cpp:3435 |
| ResolvedMethodEntry 结构 + flags 六位 | oops/resolvedMethodEntry.hpp:68 / :119 |
| lookup_virtual_method（1 条 movptr） | cpu/x86/macroAssembler_x86.cpp:4035 |
| lookup_interface_method（线性扫描） | cpu/x86/macroAssembler_x86.cpp:3841 |
| check_klass_subtype_fast_path | cpu/x86/macroAssembler_x86.cpp:4058 |
| jump_from_interpreted（最后一跳） | cpu/x86/interp_masm_x86.cpp:715 |
| load_method_entry（热路径寻址） | cpu/x86/interp_masm_x86.cpp:1855 |
