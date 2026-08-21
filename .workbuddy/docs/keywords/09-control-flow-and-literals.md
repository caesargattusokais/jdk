# 控制流 + 字面量 + 编译期型：if/for/switch/return/yield 与 true/null/void/var/assert/strictfp

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Java 关键字源码跟读 · 第 09 篇（[回到系列索引](README.md)）
> 前置：[06 instanceof](06-instanceof.md) · [07 异常处理](07-exceptions.md) · [08 final](08-final.md)

---

## 快速概览

- **一句话结论**：本批 14 个"关键字"（其实 `true/false/null` 是**字面量**、`var/_` 是**受限名称**）按机制分成三派：
  1. **机制型（有专属字节码）**：`if/else` → if 家族 0x99-0xa6；`for/while/do`、`break/continue` → `goto` 0xa7；`return` → 0xac-0xb1；`switch` → `tableswitch` 0xaa / `lookupswitch` 0xab；`yield` → 无字节码（编译进 switch，换规则 + 方法级栈保证）；
  2. **字面量型**：`true/false` → `iconst_1/0`（0x04/0x03），`null` → `aconst_null`（0x01），`void` → 描述符 `V`（`T_VOID`）；
  3. **纯编译期型**：`var`（类型推断，class 文件零痕迹）、`assert`（降级为 `if + athrow`，javac `Lower.java:3137`）、`strictfp`（`ACC_STRICT`，JDK 17+ 被剥除）、`_`（JDK 9 起保留，禁止作标识符）。
- **本批最反直觉的发现**：`lookupswitch` 的模板是 `__ stop("lookupswitch bytecode should have been rewritten")`（`templateTable_x86.cpp:2070`）——**解释器启动时会把 lookupswitch 原地改写成 `fast_linearswitch` 或 `fast_binaryswitch`**（`rewriter.cpp:410-427`），阈值是 `BinarySwitchThreshold = 5`（`globals.hpp:1579`）。
- **JDK 28 vs 教科书**：教科书还讲 `jsr/ret` 实现 finally——javac 从 Java 6 起就不生成 jsr，HotSpot 虽保留模板（`templateTable.cpp:150`）但 `goto` 模板根本不存在于 x86（goto 走共享 `branch`，见 §6）；`strictfp` 教科书说是"强制 FP 严格模式"，JDK 17（JEP 306）起 `ACC_STRICT` 直接剥除（`classFileParser.cpp:2291`），语义与 `strict` 完全相同。

---

## 目录

1. [本批"关键字"全景：三派分类](#一本批关键字全景三派分类)
2. [if/else → if 家族字节码与共享模板](#二ifelse--if-家族字节码与共享模板)
3. [for/while/do 与 break/continue → goto 与循环计数](#三forwhiledo-与-breakcontinue--goto-与循环计数)
4. [switch 双形态：javac 的成本决策公式](#四switch-双形态javac-的成本决策公式)
5. [tableswitch 模板：对齐 → 范围检查 → 跳表 O(1)](#五tableswitch-模板对齐--范围检查--跳表-o1)
6. [lookupswitch 的秘密：解释器改写机制](#六lookupswitch-的秘密解释器改写机制)
7. [return 家族：一个模板六种状态](#七return-家族一个模板六种状态)
8. [yield：受限类型名与 switch 表达式（无字节码）](#八yield受限类型名与-switch-表达式无字节码)
9. [true/false/null/void：字面量与描述符](#九truefalsenullvoid字面量与描述符)
10. [var 与 _：纯编译期成员](#十var-与-_-纯编译期成员)
11. [assert：$assertionsDisabled 降级为 if + athrow](#十一assertassertionsdisabled-降级为-if--athrow)
12. [strictfp：ACC_STRICT 与 JDK 17 的剥除](#十二strictfpacc_strict-与-jdk-17-的剥除)
13. [JDK 28 vs 教科书差异](#十三jdk-28-vs-教科书差异)
14. [验证实验](#十四验证实验)
15. [与系列主线闭环](#十五与系列主线闭环)

---

## 一、本批"关键字"全景：三派分类

| 类别 | 关键字/字面量 | 字节码痕迹 | 运行期机制 | 核心锚点 |
|---|---|---|---|---|
| **机制型** | `if/else` | if 家族 0x99-0xa6 | 共享模板 `if_0cmp`/`if_icmp`/`if_acmp`/`if_nullcmp` | `templateTable_x86.cpp:1918` |
| 机制型 | `for/while/do` | `goto` 0xa7 | backedge counter → OSR | `branch()` `templateTable_x86.cpp:1749` |
| 机制型 | `break/continue` | `goto`（无专属字节码） | 同上（break 可带 label → goto） | `bytecodes.hpp:211` |
| 机制型 | `switch` | `tableswitch` 0xaa / `lookupswitch` 0xab | 跳表 O(1) / 改写线性·二分 | `templateTable_x86.cpp:2033` |
| 机制型 | `return` | 0xac-0xb1 六种 | 共享 `_return` 模板（poll+narrow+remove_activation） | `templateTable_x86.cpp:2221` |
| 机制型 | `yield` | **无**（编译进 switch） | 受限类型名 + switch 表达式 Level 保证 | `Resolve.java:2607` |
| **字面量型** | `true/false` | `iconst_1/iconst_0`（0x04/0x03） | 常量入栈 | `bytecodes.hpp:47-48` |
| 字面量型 | `null` | `aconst_null`（0x01） | 零引用入栈 | `bytecodes.hpp:45` |
| 字面量型 | `void` | 无（描述符 `V`） | `T_VOID`（返回类型检查） | `Tokens.java:146` |
| **纯编译期型** | `var` | **无任何痕迹** | javac 局部变量类型推断 | `Resolve.java:2605` |
| 纯编译期型 | `_` | **无** | JDK 9 起保留关键字，禁止标识符 | `Tokens.java:159` |
| 纯编译期型 | `assert` | `if + athrow` 合成 | `$assertionsDisabled` 合成字段 | `Lower.java:3137` |
| 纯编译期型 | `strictfp` | `ACC_STRICT`（17- 才有） | JDK 17+ 剥除，语义等同 strict | `classFileParser.cpp:2291` |

> 判断方法照旧：**class 文件里搜不搜得到痕迹**。`if` 有专属字节码、`yield` 没有、`var` 连访问标志都没有——三派的分界线就是"javac 是否为之生成字节码"。

## 二、if/else → if 家族字节码与共享模板

### 2.1 字节码定义（bytecodes.hpp:197-210）

`if/else` 在 class 文件里是**一条指令带 2 字节相对跳转偏移**（signed short，`bcp + offset`）：

```cpp
_ifeq        = 153, // 0x99   栈顶 int == 0
_ifne        = 154, // 0x9a   != 0
_iflt        = 155, // 0x9b   < 0
_ifge        = 156, // 0x9c   >= 0
_ifgt        = 157, // 0x9d   > 0
_ifle        = 158, // 0x9e   <= 0
_if_icmpeq   = 159, // 0x9f   栈顶两 int ==
_if_icmpne   = 160, // 0xa0   !=
_if_icmplt   = 161, // 0xa1   <
_if_icmpge   = 162, // 0xa2   >=
_if_icmpgt   = 163, // 0xa3   >
_if_icmple   = 164, // 0xa4   <=
_if_acmpeq   = 165, // 0xa5   栈顶两引用 ==（同一性）
_if_acmpne   = 166, // 0xa6   !=
```

关键认知：**`else` 没有字节码**。`if (c) A; else B;` 编译为 `if_xxx 跳过A` + A + `goto 跳过B` + B——else 分支只是"if 不成立时顺序落入"的布局选择，跳转指令只有 if 家族和 goto。

### 2.2 共享模板：条件参数化（templateTable.cpp:388-401）

模板表把 14 条 if 指令映射到 **4 个模板函数 + 1 个条件参数**：

| 模板函数 | 指令 | 输入栈状态 | 实现 |
|---|---|---|---|
| `if_0cmp(Condition cc)` | ifeq/ifne/iflt/ifge/ifgt/ifle | itos | `testl` + 条件跳转 |
| `if_icmp(Condition cc)` | if_icmp* 六条 | itos | `pop_i` + `cmpl` + 条件跳转 |
| `if_acmp(Condition cc)` | if_acmpeq/if_acmpne | atos | `pop_ptr` + `cmpoop` + 条件跳转 |
| `if_nullcmp(Condition cc)` | ifnull/ifnonnull（0xc6/0xc7） | atos | `testptr` + 条件跳转 |

生成器只写一次模板，按 `cc` 参数实例化 6 个条件——这就是模板解释器"一个模板多条指令"的典型形态。

### 2.3 模板实现细节（templateTable_x86.cpp:1918-1999）

```cpp
void TemplateTable::if_0cmp(Condition cc) {
  transition(itos, vtos);
  // assume branch is more often taken than not (loops use backward branches)
  Label not_taken;
  __ testl(rax, rax);
  __ jcc(j_not(cc), not_taken);
  branch(false, false);            // 命中：统一跳转路径（profile + 计 backedge）
  __ bind(not_taken);
  __ profile_not_taken_branch(rax);// 未命中：记 profile（分支预测数据）
}
```

三个值得注意的点：

1. **注释反直觉**：解释器假设**分支更常被命中**（"loops use backward branches"）——回边分支天然偏向跳转，所以把 `branch()` 放在主路径上。
2. **`if_acmp` 有 Valhalla 渗透**（:1960-1991）：`Arguments::is_valhalla_enabled()` 时，`==` 会先测 mark word 的 `inline_type_pattern`，再测值 Klass，最后 `invoke_is_substitutable`——值对象（value class）的 `==` 语义（按内容）已经渗进解释器模板。
3. **跳转偏移处理**在 `branch()` 里：`load_signed_short(rdx, at_bcp(1))` + `bswapl` + `sarl(rdx, 16)`（:1762-1767）——读大端 s2 偏移，符号扩展为 ptr。

## 三、for/while/do 与 break/continue → goto 与循环计数

### 3.1 循环 = if + goto（无专属字节码）

`for/while/do` 都没有专属字节码。javac 把循环编译为：

```
for (init; cond; update) body
  → init
    loop: if_xxx(cond == false) → exit   // 条件出口
          body
          update
          goto loop                        // 回边
    exit:
```

- **`goto` 0xa7**（`bytecodes.hpp:211`）：2 字节有符号偏移；**`goto_w` 0xc8**（:244）：4 字节偏移（大方法专用）。
- **`break`** = `goto` 直接跳循环外；**`continue`** = `goto` 跳 update 处；带 label 的 `break label` = 跳任意外层——**全部是 goto，没有一条专属字节码**。

### 3.2 goto 模板：backedge counter 与 OSR（templateTable_x86.cpp:1749）

`_goto`/`jsr` 共享同一个 `branch(bool is_jsr, bool is_wide)`（`templateTable.cpp:132-153` 四行都是转发）：

```cpp
void TemplateTable::_goto() {
  transition(vtos, vtos);
  branch(false, false);
}
```

`branch()` 的核心（:1799-1830+）：

1. `profile_taken_branch(rax)` —— 更新 MDP（方法数据 profile），给 C2 的分支预测用；
2. 读偏移 → `addptr(rbcp, rdx)` 跳转；
3. **回边计数**：`testl(rdx, rdx); jcc(positive, dispatch)` —— **只有向后分支（backward branch）才计数**（:1806-1807），前向分支直接 dispatch；
4. 计数在 `MethodCounters::backedge_counter`（:1753），**counter 溢出 → OSR 编译**（栈上替换）：循环体被编译成编译态版本，当前解释器帧原位替换——这就是热循环"跑着跑着被 JIT 接管"的机制。

> 与 04 篇呼应：`-XX:CompileThreshold` 管方法级入口计数，**回边计数管循环级 OSR**，两条路都是 JIT 的触发源。

## 四、switch 双形态：javac 的成本决策公式

### 4.1 两种字节码（bytecodes.hpp:214-215）

```cpp
_tableswitch   = 170, // 0xaa   密集：跳表 O(1)
_lookupswitch  = 171, // 0xab   稀疏：键值对表 O(n)/O(log n)
```

`tableswitch` 的布局：`default 偏移 + lo + hi + (hi-lo+1) 个跳转偏移`（**4 字节对齐**，`Gen.java:1395 code.align(4)`）。
`lookupswitch` 的布局：`default 偏移 + 对数 n + n 组 (key, 偏移)`。

### 4.2 javac 的选择公式（Gen.java:1380-1391）

```java
long table_space_cost  = 4 + ((long) hi - lo + 1); // 跳表占的字数
long table_time_cost   = 3;                         // 比较次数（固定 3 步）
long lookup_space_cost = 3 + 2 * (long) nlabels;    // 键值对表占的字数
long lookup_time_cost  = nlabels;                   // 比较次数（线性）
int opcode =
    nlabels > 0 &&
    table_space_cost + 3 * table_time_cost <=
    lookup_space_cost + 3 * lookup_time_cost
    ? tableswitch : lookupswitch;
```

**这是空间与时间的权衡**：跳表空间大（要覆盖 `hi-lo+1` 个槽）但比较固定 3 步；键值表空间省（只有 n 对）但比较次数随 case 数增长。时间成本加权 3 倍（因为跳表比较次数少）。**case 值密集 → tableswitch，稀疏 → lookupswitch**。

> 经典例子：`case 0,1,2,3` → tableswitch（4 个槽全用）；`case 0,1000,2000` → lookupswitch（3 对键值）。

## 五、tableswitch 模板：对齐 → 范围检查 → 跳表 O(1)

### 5.1 模板五步（templateTable_x86.cpp:2033-2066）

```cpp
void TemplateTable::tableswitch() {
  transition(itos, vtos);
  // ① 4 字节对齐 rbx（tableswitch 表必须对齐）
  __ lea(rbx, at_bcp(BytesPerInt));
  __ andptr(rbx, -BytesPerInt);
  // ② 读 lo & hi（大端 bswap）
  __ movl(rcx, Address(rbx, BytesPerInt));
  __ movl(rdx, Address(rbx, 2 * BytesPerInt));
  __ bswapl(rcx); __ bswapl(rdx);
  // ③ 范围检查：key < lo 或 key > hi → default
  __ cmpl(rax, rcx);
  __ jcc(Assembler::less, default_case);
  __ cmpl(rax, rdx);
  __ jcc(Assembler::greater, default_case);
  // ④ 查跳表：offset = table[key - lo]
  __ subl(rax, rcx);
  __ movl(rdx, Address(rbx, rax, Address::times_4, 3 * BytesPerInt));
  __ profile_switch_case(rax, rbx, rcx);
  // ⑤ 跳转：rbcp += offset，dispatch 下一条
  __ bswapl(rdx);
  __ addptr(rbcp, rdx);
  __ dispatch_only(vtos, true);
}
```

一次 `sub` + 一次内存访问 = **O(1) 分发**，无需任何比较（范围检查算 2 次）。这就是教科书里"switch 比 if-else 链快"的真正来源——但只在**密集 case** 下成立。

### 5.2 对齐的讲究

tableswitch 的跳表起始位置要求 4 字节对齐，**补齐字节是 padding 不是操作码**——所以模板先 `lea + andptr(-4)` 手动对齐，再按 `rbx` 基址读表。这也是为什么 tableswitch 的字节码长度在 class 文件里是**可变的**（要算 padding），`Bytecodes::length_at` 会特判（`rewriter.cpp:393-394`）。

## 六、lookupswitch 的秘密：解释器改写机制

### 6.1 模板直接拒绝（templateTable_x86.cpp:2068-2071）

```cpp
void TemplateTable::lookupswitch() {
  transition(itos, itos);
  __ stop("lookupswitch bytecode should have been rewritten");
}
```

**生产环境永远执行不到这里**——类加载时 rewriter 会把 lookupswitch 原地改写。

### 6.2 改写决策（rewriter.cpp:410-427）

```cpp
case Bytecodes::_lookupswitch: {
  Bytecode_lookupswitch bc(method, bcp);
  (*bcp) = (
    bc.number_of_pairs() < BinarySwitchThreshold
    ? Bytecodes::_fast_linearswitch   // 少数 case：线性扫描
    : Bytecodes::_fast_binaryswitch   // 多数 case：二分查找
  );
  break;
}
```

- **`BinarySwitchThreshold = 5`**（`globals.hpp:1579`，develop flag）：
  - case 对数 < 5 → `fast_linearswitch`：**线性扫描**（O(n)，n 小时 cache 友好）；
  - case 对数 ≥ 5 → `fast_binaryswitch`：**二分查找**（O(log n)，注释还引用了 Dijkstra 的《Methodik des Programmierens》不变式算法，:2113-2124）。
- **逆转**：模板表里 `fast_linearswitch`/`fast_binaryswitch` 的"上一级"定义是 `_lookupswitch`（`bytecodes.cpp:63-64`），反向 rewrite（卸载场景）时还原（rewriter.cpp:421-426）。

### 6.3 二分模板（templateTable_x86.cpp:2111+）

`fast_binaryswitch` 用**标准二分**（i=0, j=n 不变式），key 命中后 `profile_switch_case(rcx, ...)` 记录命中位置——profile 数据会告诉 C2 哪些 case 热，C2 据此生成跳转树（binary decision tree），比解释器的二分更快（多分支预测）。

## 七、return 家族：一个模板六种状态

### 7.1 六条指令共享 `_return` 模板（templateTable.cpp:407-412）

```cpp
def(Bytecodes::_ireturn, ____|disp|clvm|____, itos, itos, _return, itos);
def(Bytecodes::_lreturn, ____|disp|clvm|____, ltos, ltos, _return, ltos);
def(Bytecodes::_freturn, ____|disp|clvm|____, ftos, ftos, _return, ftos);
def(Bytecodes::_dreturn, ____|disp|clvm|____, dtos, dtos, _return, dtos);
def(Bytecodes::_areturn, ____|disp|clvm|____, atos, atos, _return, atos);
def(Bytecodes::_return , ____|disp|clvm|____, vtos, vtos, _return, vtos);
```

`ireturn`=0xac … `return`=0xb1（`bytecodes.hpp:216-221`），唯一的区别是 **TosState**（栈顶类型状态）：int/long/float/double/引用/void。

### 7.2 `_return` 模板三步（templateTable_x86.cpp:2221-2265）

```cpp
void TemplateTable::_return(TosState state) {
  transition(state, state);
  // ① safepoint poll（_return_register_finalizer 除外）
  __ testb(Address(r15_thread, JavaThread::polling_word_offset()),
           SafepointMechanism::poll_bit());
  __ jcc(Assembler::zero, no_safepoint);
  __ call_VM(noreg, ... InterpreterRuntime::at_safepoint);
  // ② itos 收窄（结果类型是 byte/short/char/boolean 时）
  if (state == itos) { __ narrow(rax); }
  // ③ 撤激活帧 → 跳转调用者
  __ remove_activation(state, rbcp, true, true, true);
  __ jmp(rbcp);
}
```

1. **方法出口也是 safepoint 点**：poll 位检查（:2244），触发则进 VM（GC 安全点）；
2. **`narrow(rax)`（:2258-2260）**：编译态调用者要求返回值已收窄——解释器在 return 时把 int 结果窄化到 byte/short/char/boolean，保证两种执行引擎结果一致；
3. **`remove_activation`**：弹出解释器帧、恢复调用者 rbcp/栈帧，衔接 07 篇——无 handler 的异常上抛也走这个函数。

### 7.3 `return_register_finalizer` 彩蛋（:2227-2239）

JDK 内部把 `Object.<init>` 返回点改写成 `_return_register_finalizer`（`templateTable.cpp:492`）：先查 Klass 的 `_misc_has_finalizer` 位，有 finalizer 就调 `InterpreterRuntime::register_finalizer`——这是 JEP 421 之后 finalizer 唯一的"注册"路径（衔接 Object 07 篇）。

## 八、yield：受限类型名与 switch 表达式（无字节码）

### 8.1 语法层：受限标识符（JavacParser.java:250-252, 2949）

```java
/** Switch: is yield statement allowed in this source level? */
boolean allowYieldStatement;      // JDK 14+（JEP 361）
...
if (token.name() == names.yield && allowYieldStatement) { ... }
```

`yield` 是 **受限标识符（restricted identifier）**：不是关键字，但在 switch 表达式上下文里被解析为 yield 语句；**脱离该上下文可用作普通标识符**。引用为类型时 javac 报 `BadRestrictedTypeError` / 警告 `IllegalRefToRestrictedType`（`Resolve.java:2607-2611`）。

### 8.2 语义层：switch 表达式的 Level 保证（Attr.java:2394-2395）

```java
if (env.info.yieldResult != null) {
  attribTree(tree.value, env, env.info.yieldResult);   // case 的值按 yieldResult 类型约束
}
```

switch 表达式（JDK 14+，JEP 361/440）的每个 case 必须 `yield` 或 `throw`，不允许 fall-through——javac 用 `yieldResult` 把"switch 表达式的期望结果类型"传给每个 case，保证**表达式必然产出值**（或抛异常），这是"表达式有值"的编译期证明。**yield 不产生任何字节码**：switch 表达式整体还是编译成 tableswitch/lookupswitch，case 里的 yield 值按普通求值路径走（结果通过栈/局部变量传递）。

> 与 08 篇呼应：`yield` 和 `final` 的局部变量形态一样——**纯编译期约束，运行期零痕迹**。

## 九、true/false/null/void：字面量与描述符

### 9.1 它们不是关键字（Tokens.java:156-159）

```java
TRUE("true", Tag.NAMED),   // :156  —— 布尔字面量
FALSE("false", Tag.NAMED), // :157
NULL("null", Tag.NAMED),   // :158  —— null 字面量
UNDERSCORE("_", Tag.NAMED),// :159  —— JDK 9 保留，禁止标识符
```

JLS §3.9 明说：**`true`、`false`、`null` 是字面量，不是关键字**。它们在 class 文件里有专属指令：

| 字面量 | 字节码 | 锚点 |
|---|---|---|
| `true` | `iconst_1`（0x04） | `bytecodes.hpp:48` |
| `false` | `iconst_0`（0x03） | `bytecodes.hpp:47` |
| `null` | `aconst_null`（0x01） | `bytecodes.hpp:45` |

`iconst_*` 家族覆盖 -1..5（0x02-0x08），更大整数走 `ldc` 常量池；`is_const()` 的区间判定是 `_aconst_null <= code <= _ldc2_w`（:420），`is_zero_const()` 把 `aconst_null` 和 `iconst_0` 并列为零常量（:421）——C2 常用这个判定做零值折叠。

### 9.2 void：描述符 V（Tokens.java:146）

`void` 是**真正的关键字**（Tag.NAMED），但只在两个地方有意义：

1. **方法返回类型**：描述符为 `V`，`T_VOID`。class 文件验证器/解析器在方法签名解析时处理；
2. **`void.class`**：`Void.TYPE`（`Class<Void>`），合法的类字面量。

它没有字节码（`return` 0xb1 才是"void 返回"的指令），所以归入"字面量/描述符型"。

## 十、var 与 _：纯编译期成员

### 10.1 var：局部变量类型推断（Resolve.java:2605-2606）

```java
if (allowLocalVariableTypeInference && name.equals(names.var)) {
  bestSoFar = new BadRestrictedTypeError(names.var);  // 引用 var 类型 → 报错
}
```

- `var` 是**受限类型名（restricted type name）**（JEP 286）：不是关键字（`var` 仍可用作方法名/变量名），但在声明上下文被 javac 解释为"类型推断占位"；
- 推断产物**在 class 文件里零痕迹**：局部变量的类型是 javac 内部算出来的，`LocalVariableTable` 里记录的还是推断后的真实类型；
- 受限类型名机制统一处理了 `var`、`yield`（JDK 14）和未来的受限名（如 `record` 的前身之一）——`BadRestrictedTypeError` 类在 `Resolve.java:4245`。

### 10.2 _：JDK 9 起的保留字（Tokens.java:159）

- Java 8 及以前：`_` 是合法标识符；
- **JDK 9 起 `_` 是保留关键字**：作标识符直接编译错误（"as of release 9, '_' is a keyword"），javac 只允许它出现在 lambda 参数省略位置（`(a, _) -> ...`？——不，JDK 9 连这个也禁了，纯占位用途已无）；
- class 文件层面**没有任何痕迹**——纯粹的语言层禁令。

## 十一、assert：$assertionsDisabled 降级为 if + athrow

### 11.1 降级规则（Lower.java:3137-3157）

```java
public void visitAssert(JCAssert tree) {
  tree.cond = translate(tree.cond, syms.booleanType);
  if (!tree.cond.type.isTrue()) {                     // 条件不是编译期 true
    JCExpression cond = assertFlagTest(tree.pos());   // 读 $assertionsDisabled
    ...
    if (!tree.cond.type.isFalse()) {
      cond = makeBinary(AND, cond, makeUnary(NOT, tree.cond));  // disabled==false && !cond
    }
    result = make.If(cond,
                     make.Throw(makeNewClass(syms.assertionErrorType, exnArgs)),
                     null);
  } else {
    result = make.Skip();                             // 条件恒 true：整个删掉
  }
}
```

`assert cond : detail` 被降级为：

```java
if (!$assertionsDisabled && !cond) throw new AssertionError(detail);
```

### 11.2 合成字段（Lower.java:99, 126-127）

```java
dollarAssertionsDisabled = names.fromString(target.syntheticNameChar() + "assertionsDisabled");
```

- 每个类生成**合成字段 `$assertionsDisabled`**，在 `<clinit>` 里按**类加载器的断言启用状态**初始化（`-ea`/`-da`）；
- **运行期零成本**：`-da`（默认）时字段为 true，每个 assert 只多一条 `if (true && ...)`——不，准确说 `disabled==true` 时条件短路，assert 体直接跳过，代价只是**读一次静态字段 + 一次分支**；
- 常量折叠：`assert true` 整个变 `make.Skip()`（无字节码）；`assert false` 只留 `throw new AssertionError()`（保留 flag 检查的前提是 detail 可能昂贵？——不，恒假分支也会先测 flag，见代码 :3143 的条件）。

## 十二、strictfp：ACC_STRICT 与 JDK 17 的剥除

### 12.1 现状：JDK 17（JEP 306）后严格模式是常态

`classFileParser.cpp:2291` 是**剥除的直接证据**（解析 `<clinit>` 的标志时）：

```cpp
flags &= JVM_ACC_STATIC | (_major_version <= JAVA_16_VERSION ? JVM_ACC_STRICT : 0);
```

**class 文件版本 ≤ 16 才保留 ACC_STRICT，17+ 直接清零**。类级解析同样只认老版本（:4693 `is_strict = (flags & JVM_ACC_STRICT)`，配 :4717 的兼容注释）。

### 12.2 语义：strict 与 strictfp 已无区别

- Java 17 前：`strictfp` 强制 FP-strict（x87 扩展精度时代需要显式关闭）；非 strictfp 允许 excess precision；
- **JEP 306 起**：FP 严格模式成为**默认且唯一**（SSE2 普及后 excess precision 无意义），`strictfp` 关键字**语义上变成 no-op**，但为了源码兼容**保留为关键字**（`Tokens.java:137 STRICTFP("strictfp")`）；
- 编译器继续接受它，但不写 ACC_STRICT（写了也会被上面的代码清零）。

> 这是一个"关键字存活但机制死亡"的标本：**语言层保留语法，class 文件层剥除标志，运行期完全无感**。

## 十三、JDK 28 vs 教科书差异

| 教科书说法 | JDK 28 真相 | 锚点 |
|---|---|---|
| `jsr/ret` 实现 finally 子程序 | javac 从 Java 6 起**不生成 jsr**（finally 靠复制，见 07 篇）；HotSpot 保留模板仅为兼容旧 class | `templateTable.cpp:150`、07 篇 § |
| `switch` 就是跳表 O(1) | 只有**密集 case** 才是 tableswitch O(1)；稀疏 case 用 lookupswitch，解释器改写为线性（<5 对）或二分（≥5 对） | `rewriter.cpp:413-417`、`globals.hpp:1579` |
| `strictfp` 强制严格模式 | JDK 17+ 默认严格，`ACC_STRICT` 在 classFileParser 被清零，关键字变 no-op | `classFileParser.cpp:2291` |
| `true/false/null` 是关键字 | JLS 明说它们是**字面量**（布尔字面量 / null 字面量） | `Tokens.java:156-158` |
| `var` 是关键字 | 是**受限类型名**，可用作方法名；class 文件零痕迹 | `Resolve.java:2605` |
| `yield` 是关键字 | 是**受限标识符**，仅 switch 表达式上下文生效；无字节码 | `JavacParser.java:250` |
| `break`/`continue` 有专属字节码 | **没有**，全部编译成 `goto`（带 label 也一样） | `bytecodes.hpp:211` |
| `assert` 有专属字节码 | **没有**，降级为 `if + $assertionsDisabled + athrow` | `Lower.java:3137` |
| `return` 就是一条指令 | 6 条指令共享一个模板；出口含 **safepoint poll + 结果收窄 + remove_activation** | `templateTable_x86.cpp:2221` |
| 循环"条件检查"在开头 | 解释器模板**假设回边分支更常命中**（profile + backedge counter → OSR） | `templateTable_x86.cpp:1920` |

## 十四、验证实验

用自己编译的 `D:\project\jdk\build\windows-x86_64-server-release\images\jdk` 实测：

### 实验 1：javac 的 switch 决策

```java
// SwitchShape.java
public class SwitchShape {
    static int dense(int x) {            // 密集 → tableswitch
        switch (x) { case 0: return 1; case 1: return 2; case 2: return 3; default: return 0; }
    }
    static int sparse(int x) {           // 稀疏 → lookupswitch
        switch (x) { case 0: return 1; case 100: return 2; case 1000: return 3; default: return 0; }
    }
}
```

```bash
javac SwitchShape.java && javap -c -p SwitchShape | grep -E "switch"
# 期望：dense → tableswitch；sparse → lookupswitch
```

### 实验 2：lookupswitch 改写（验证 BinarySwitchThreshold=5）

```java
// ManyCases.java
static int many(int x) {
    switch (x) {
        case 10: case 20: case 30: case 40: case 50: case 60:   // 6 对 > 5 → 二分
        case 70: case 80: return 1; default: return 0;
    }
}
```

```bash
java -Xint -XX:+UnlockDiagnosticVMOptions -XX:CompileCommand=print,*ManyCases.many ManyCases
# -Xint 强制解释器，观察 fast_binaryswitch 路径（或用 gdb 断 templateTable 的 fast_binaryswitch）
```

### 实验 3：assert 的 $assertionsDisabled

```java
// AssertDemo.java
public class AssertDemo {
    public static void main(String[] a) { assert 1 + 1 == 3 : "broken"; }
}
```

```bash
javap -p -c AssertDemo | grep -A5 assertionsDisabled
# 期望：$assertionsDisabled 合成字段 + <clinit> 里按断言状态赋值 + main 里 if 分支
```

### 实验 4：strictfp 的 ACC_STRICT 消失

```java
// StrictDemo.java
public strictfp class StrictDemo { public strictfp double f(double x) { return x * x; } }
```

```bash
javap -v StrictDemo | grep -i strict
# 期望（JDK 28）：类/方法访问标志里都没有 ACC_STRICT（版本 61+ 被剥除）
```

## 十五、与系列主线闭环

1. **07 篇的异常表**：`throw`/`athrow` 是 09 篇 `assert` 降级的终点——`assert` 最终编译成 `if + athrow`，异常处理链路复用 07 篇的 `fast_exception_handler_bci_for`；
2. **04 篇的 OSR 衔接**：循环回边计数溢出触发 OSR（栈上替换），把解释器帧原位换成编译帧——`branch()` 模板是解释器→JIT 的"换挡"点；
3. **06 篇的 Valhalla**：`if_acmp` 模板里的 value-class substitutable 比较，说明 `==` 语义正在被 Valhalla 改写，与 06 篇 instanceof 的 inline type 分支同源；
4. **08 篇的编译期 vs 运行期坐标**：`final` 局部变量、`yield`、`var`、`_` 四个"无字节码"成员互相印证——**纯编译期约束的共同特征是 class 文件无痕**；
5. **05 篇的 clinit**：`$assertionsDisabled` 在 `<clinit>` 里初始化——又一个"合成字段 + clinit 赋值"的模式（05 篇 static 的机制在 assert 上的应用）。

下一篇（10）：**声明域 + 访问控制 + module 补完篇**——`class/interface/enum/record/extends/implements/abstract/sealed/permits`、`public/protected/private/package/import/transient`、module 系与 `module-info.class` 解析。
