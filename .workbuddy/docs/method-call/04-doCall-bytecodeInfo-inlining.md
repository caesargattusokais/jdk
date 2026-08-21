# 方法调用全链路 · 第四站：C2 去虚化与内联（doCall + bytecodeInfo）

> **快速概览**：前三站是**解释器视角**——01 管解析（冷路径写缓存）、02 管建表（vtable/itable）、03 管热路径查表跳转。这一站换成 **C2（JIT）视角**：方法跑热被编译时，编译器面前同样是一条 `invokevirtual`，但它有权**选择"不调用"**——要么用 CHA（类层次分析）或类型 profile 把多态压成**直接调用/内联**，要么保留虚调用。决策链藏在 `opto/doCall.cpp`（选路）+ `opto/bytecodeInfo.cpp`（内联成本账）+ `opto/callGenerator.cpp`（生成器工厂）三份文件里：**四连问（能否静态绑定 → 有无 receiver 情报 → CHA 是否唯一 → 类型是否精确）→ 决策总闸 → 生成 IR**。
>
> **关联站**：01（linkResolver 解析）→ 02（vtable/itable 建表）→ 03（解释器热路径）→ **04（本站在 JIT 侧把调用抹平）**。08 篇"final 方法可内联"在这里找到编译期依据：`Method::is_final_method()` 就是 `optimize_inlining` 的第一道闸门。

---

## TOC

- [一、视角切换：从"执行"到"不执行"](#一视角切换从执行到不执行)
- [二、四段链总览：do_call → optimize_virtual_call → call_generator → generate](#二四段链总览do_call--optimize_virtual_call--call_generator--generate)
- [三、入口：Parse::do_call 的三问](#三入口parse-do_call-的三问)
- [四、第一问：能不能静态绑定（final 闭环）](#四第一问能不能静态绑定final-闭环)
- [五、第二问：receiver 类型情报与数组特例](#五第二问receiver-类型情报与数组特例)
- [六、第三问：CHA 找唯一实现](#六第三问cha-找唯一实现)
- [七、第四问：类型是否精确](#七第四问类型是否精确)
- [八、决策总闸：call_generator 的路线图](#八决策总闸call_generator-的路线图)
- [九、路线 A：类型 profile 守卫内联（PredictedCallGenerator）](#九路线-a类型-profile-守卫内联predictedcallgenerator)
- [十、路线 B：多态兜底与路线 C：直接调用](#十路线-b多态兜底与路线-c直接调用)
- [十一、内联成本账：bytecodeInfo](#十一内联成本账bytecodeinfo)
- [十二、生成 IR 与收尾 + 四站闭环](#十二生成-ir-与收尾--四站闭环)
- [十三、行号速查表](#十三行号速查表)

---

## 一、视角切换：从"执行"到"不执行"

解释器（03 站）的哲学是**每次调用都老老实实跑**：查 RME、查表、跳转。C2 的哲学相反——**跑热的代码值得花编译时间去消灭调用本身**：

| 视角 | 问题 | 回答方式 | 成本 |
|---|---|---|---|
| 解释器（03 站） | 这条 invoke 怎么执行？ | 查表 + 跳转，**每次调用都付** | 5 条寻址 + 1 次查表 + 1 条 jmp |
| C2（本站） | 这条 invoke 能不能不执行？ | 静态绑定 / CHA / profile / 内联，**编译期付一次** | 编译时间 + 去优化风险 |

C2 的底气来自三样东西：

1. **编译期"快照"**：类加载是动态的，但 C2 在编译瞬间可以锁定当前类层次（CHA），并**记录依赖**（`dependencies()`）——将来动态加载新类破坏假设时，VM 会**撤销已编译代码**（重新编译），这就是"去优化（deoptimization）"的安全网。
2. **解释器留下的档案**：03 站热路径里那条 `profile_virtual_call`，把每个调用点的**接收者类型分布**写进 MDO（Method Data）——C2 读它来决定"这个调用点多数时候是哪个类"。
3. **final 语义**：08 篇讲过的 `is_final_method()` 在这里是**第一道闸门**——final 方法根本不需要 CHA，直接静态绑定。

> 💡 **一句话**：解释器把方法"调起来"，C2 把方法"抹平"——本系列走到第四站，主题从"怎么执行"变成"怎么不执行"。

## 二、四段链总览：do_call → optimize_virtual_call → call_generator → generate

C2 解析一条 invoke 字节码时，走一条**四段决策链**（全部在 `doCall.cpp` + `callGenerator.cpp`）：

```
┌─────────────────────────────────────────────────────────────────┐
│ ① Parse::do_call（doCall.cpp:550）                                │
│    编译期遇到 invoke 字节码 → 三问（是否虚调用/有无 receiver/能否链接） │
└──────────────────────────────┬──────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ ② Compile::optimize_virtual_call（doCall.cpp:1169）               │
│    四连问收集情报：静态绑定？receiver 类型？CHA 唯一？exact？         │
│    输出 out-参数：call_does_dispatch + vtable_index               │
└──────────────────────────────┬──────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ ③ Compile::call_generator（doCall.cpp:94）                        │
│    决策总闸：intrinsic → 内联 → profile 守卫 → 多态兜底             │
│    返回一个 CallGenerator（生成器）                                │
└──────────────────────────────┬──────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ ④ cg->generate（callGenerator.cpp:116/183/254/1070）              │
│    生成器把调用"翻译"成 IR：解析内联 / 直接调用 / 守卫菱形 / 保留多态   │
└─────────────────────────────────────────────────────────────────┘
```

**关键概念：call_does_dispatch 标志**——它是 ② 段的输出、③ 段的输入，决定整个决策走向：

- `call_does_dispatch = false`：这个调用点**不需要运行时多态分派**（静态绑定 / CHA 唯一目标 / exact 类型）→ 直接调用甚至内联
- `call_does_dispatch = true`：**仍然是多态** → 要么靠类型 profile 加守卫赌一把，要么老实保留虚调用

> 💡 在 doCall.cpp:614-617，C2 先**假设** `call_does_dispatch = false`（乐观），由 `optimize_virtual_call` 逐一排除，最后拿不准时才翻回 `true`。

## 三、入口：Parse::do_call 的三问

`Parse::do_call`（doCall.cpp:550）是编译期解析 invoke 字节码的总入口，先做三问：

```cpp
// doCall.cpp:557-559 —— 问 1/2：这是什么调用？
const bool is_virtual = bc() == Bytecodes::_invokevirtual;
const bool is_virtual_or_interface = is_virtual || bc() == Bytecodes::_invokeinterface;
const bool has_receiver = Bytecodes::has_receiver(bc());
```

```cpp
// doCall.cpp:562-567 —— 问 3：字节码里的方法是谁？
ciMethod* orig_callee = iter().get_method(will_link, &declared_signature);  // callee in the bytecode
ciInstanceKlass* holder_klass = orig_callee->holder();
ciKlass* holder = iter().get_declared_method_holder();
```

- **问 1/2**：`invokevirtual` / `invokeinterface` 是多态候选（`is_virtual_or_interface`）；`invokestatic` / `invokespecial` 天然静态绑定。`has_receiver` 决定后面要不要做 null 检查和 receiver 类型分析。
- **问 3**：`get_method` 拿到的是**符号解析层的结果**（01 站 linkResolver 的产物），但类可能还没加载完——所以紧接着是链接检查：

```cpp
// doCall.cpp:577-585 —— 链接失败 → 不编译这个调用点
if (!will_link || can_not_compile_call_site(orig_callee, klass)) {
  ...
  return;
}
```

如果类未加载 / 链接失败，C2 **放弃编译这个调用点**（让解释器继续兜底）——这是"不会出错的编译器"的第一道防线。

> 💡 之后（:614-617）初始化三件套：`callee = orig_callee`、`vtable_index = invalid_vtable_index`、`call_does_dispatch = false`——**乐观假设"不分派"**，交给下一段逐一验证。

## 四、第一问：能不能静态绑定（final 闭环）

`optimize_inlining`（doCall.cpp:1194）的第一个动作，是问**方法本身**：

```cpp
// doCall.cpp:1199-1205
// If it is obviously final, do not bother to call find_monomorphic_target,
// because the class hierarchy checks are not needed...
if (callee->can_be_statically_bound()) {
  return callee;
}
```

`can_be_statically_bound` 的根源在 Method 层（method.cpp:876）：

```cpp
// oops/method.cpp:876-893
bool Method::can_be_statically_bound(AccessFlags class_access_flags) const {
  if (is_final_method(class_access_flags))  return true;
  ...
}

// oops/method.cpp:854-860 —— final 判定的真身
bool Method::is_final_method(AccessFlags class_access_flags) const {
  if (is_overpass() || is_default_method())  return false;
  return is_final() || class_access_flags.is_final();
}
```

**这就是 08 篇的编译期闭环**：

| 情形 | is_final_method | 结论 |
|---|---|---|
| 方法声明 `final` | `is_final() == true` | 静态绑定 |
| **类是 `final class`** | `class_access_flags.is_final() == true` → 全部方法隐式 final | 静态绑定 |
| `private` 方法 | ciMethod.cpp:137 显式修正 `_can_be_statically_bound = true` | 静态绑定 |
| `static` 方法 | 无 receiver，天然静态绑定 | 静态绑定 |

> 💡 **为什么"不再做 CHA"**（注释 :1199-1201）：final 方法的槽位是编译期就锁死的，查类层次纯属浪费，而且**可能因为类还没加载完而误判失败**。C2 对自己的类加载检查有信心，直接绑。

命中即返回：`call_does_dispatch = false`，**整条多态链被短路**——这就是"final 方法可内联"的编译期第一依据。

## 五、第二问：receiver 类型情报与数组特例

没被静态绑定拦下，说明是真正的虚调用。第二问：**编译器手里有没有 receiver 的类型情报**？

```cpp
// doCall.cpp:1207-1220
if (receiver_type == nullptr) {
  return nullptr; // no receiver type info
}

// Array methods are all inherited from Object, and are monomorphic.
if (receiver_type->isa_aryptr() &&
    callee->holder() == env()->Object_klass() &&
    callee->name() != ciSymbols::finalize_method_name()) {
  return callee;   // 数组方法（clone/hashCode 等）一律单态，直接绑
}
```

- **没有 receiver 类型**（`receiver_type == nullptr`）→ 情报不足，`return nullptr` → 保持多态。
- **数组特例**：数组类型的方法全部继承自 Object（clone、hashCode、equals…），**天然单态**——直接绑定，不用查层次。（注意 `finalize()` 被排除——数组上调 finalize 是非法字节码，不能错误地静态绑定。）

> 💡 为什么 receiver 类型这么重要：C2 的 IR 里每个值都有**类型系统**（`TypeOopPtr`），它是编译期从字节码静态类型 + 之前的分支分析推出来的。类型越精确，后面能做的优化越多。

## 六、第三问：CHA 找唯一实现

有 receiver 类型后，第三问是**类层次分析（CHA）**：目标方法在整棵类层次里，是不是只有**一个**可能的实现？

```cpp
// doCall.cpp:1237-1238
ciInstanceKlass* calling_klass = caller->holder();
ciMethod* cha_monomorphic_target = callee->find_monomorphic_target(calling_klass, klass, actual_receiver, check_access);
```

`find_monomorphic_target` 顺着**接收者实际类**往上查：如果 `actual_receiver` 的继承链上只有一个类实现了这个方法（其它都是 abstract），就找到了唯一实现。

命中后的关键一步——**记录依赖**：

```cpp
// doCall.cpp:1240-1253
if (cha_monomorphic_target != nullptr) {
  // Hardwiring a virtual.
  ...
  if (!cha_monomorphic_target->can_be_statically_bound(actual_receiver)) {
    // If we inlined because CHA revealed only a single target method,
    // then we are dependent on that target method not getting overridden
    // by dynamic class loading. ...
    dependencies()->assert_unique_concrete_method(actual_receiver, cha_monomorphic_target, holder, callee);
  }
  return cha_monomorphic_target;
}
```

**为什么必须记依赖**：CHA 的结论是"**当前**类层次里唯一"。Java 是动态加载的——编译完成后新类可能加载进来覆写这个槽位。`assert_unique_concrete_method` 把假设登记进编译依赖表：**一旦新类破坏假设，nmethod 被标记失效，下次调用重新编译**（去优化）。这是"乐观优化 + 安全回滚"的完整闭环。

> 💡 **接口单实现者的变体**（doCall.cpp:346-387）：`call_generator` 里还有一条 CHA 路径专门处理接口——`declared_interface->unique_implementor()` 找到接口的**唯一实现类**，再 `find_monomorphic_target` 找具体方法，用 `for_guarded_call` 包一层类型守卫（见第九节），并记两条依赖：`assert_unique_implementor` + `assert_unique_concrete_method`。

## 七、第四问：类型是否精确

CHA 没找到唯一实现（多态确实存在），第四问：**receiver 的类型是否精确（exact）**？

```cpp
// doCall.cpp:1255-1264
// If the type is exact, we can still bind the method w/o a vcall.
if (actual_receiver_is_exact) {
  ciMethod* exact_method = callee->resolve_invoke(calling_klass, actual_receiver);
  if (exact_method != nullptr) {
    return exact_method;
  }
}
```

- **exact 类型**（`klass_is_exact()`）：receiver 的类被证明**不可能有子类**——比如 `new Dog()` 的直接结果、final class 的实例（呼应 08 篇 `ciInstanceKlass::exact_klass`）。此时 `resolve_invoke` 直接解析出方法，**不需要 CHA、不需要 vtable**。
- 到这里还没绑上 → `optimize_inlining` 返回 `nullptr` → `call_does_dispatch = true`（doCall.cpp:1183-1185 不置 false），真正保持多态。

四连问完整版：

| 问 | 检查 | 命中 → | 未命中 → |
|---|---|---|---|
| ① 静态绑定？ | `can_be_statically_bound`（method.cpp:876） | 直接绑 | 下一问 |
| ② 有 receiver 情报？ | `receiver_type != null`（:1207） | 继续 | 保持多态 |
| ③ CHA 唯一？ | `find_monomorphic_target`（:1238） | 绑 + 记依赖 | 下一问 |
| ④ 类型 exact？ | `klass_is_exact`（:1257） | resolve 直绑 | **多态** |

## 八、决策总闸：call_generator 的路线图

`Compile::call_generator`（doCall.cpp:94）是整条链的**决策总闸**。它先读 profile，然后按 `call_does_dispatch` 分路：

```cpp
// doCall.cpp:100-107 —— 判定调用形态
const bool is_virtual = (bytecode == Bytecodes::_invokevirtual) || ...;
const bool is_interface = (bytecode == Bytecodes::_invokeinterface) || ...;
const bool is_virtual_or_interface = is_virtual || is_interface;

// doCall.cpp:119-128 —— 读解释器留下的档案
ciCallProfile profile = caller->call_profile_at_bci(bci);   // MDO 里的调用点档案
int site_count = profile.count();                           // 这个调用点被调了多少次
int receiver_count = -1;
if (call_does_dispatch && UseTypeProfile && profile.has_receiver(0)) {
  receiver_count = profile.receiver_count(0);               // 头号接收者被调次数
}
```

**路线图**（按优先级）：

```
call_generator（doCall.cpp:94）
│
├─ [1] intrinsic 优先（:153-178）
│    find_intrinsic(callee, ...) → 库里方法直接换专用代码（如 StringBuilder）
│    · 会做虚拟分派的 intrinsic → 寄存（cg_intrinsic），先让类型 profile 试试
│
├─ [2] 非多态（!call_does_dispatch）→ 试内联（:198-232）
│    InlineTree::ok_to_inline → CallGenerator::for_inline（ParseGenerator）
│    · 虚调用内联 → 再包一层 guarded_call（receiver 约束陷阱）
│
├─ [3] 多态 → 类型 profile（:234-330）
│    · 单态（morphism==1）/ 双态（morphism==2 且 UseBimorphicInlining）
│      → for_predicted_call：命中内联 / miss 走 uncommon_trap（第九节）
│
├─ [4] CHA 接口单实现者（:346-387）
│    unique_implementor → for_guarded_call + 双依赖
│
├─ [5] 多态兜底（:397-419）
│    call_does_dispatch → for_virtual_call（保留虚调用，CallDynamicJavaNode）
│    非多态但没内联成 → for_direct_call（CallStaticJavaNode）
```

> 💡 **为什么 intrinsic 排第一**：库里方法（`StringBuilder.append`、`System.arraycopy` 等）的专用代码比通用内联强得多——它们有 JIT 手写的 IR 模式，甚至直接生成 SIMD 指令。但"会做虚拟分派的 intrinsic"（如 `linkToVirtual`）要让位给类型 profile，因为后者有机会**连 receiver 一起优化掉**。

## 九、路线 A：类型 profile 守卫内联（PredictedCallGenerator）

多态调用点的最高级玩法：**加一个运行时类型守卫，命中就内联，没命中就撤退**。

先判断"值得赌"（doCall.cpp:234-269）：

```cpp
// doCall.cpp:237 —— 头号接收者占比 ≥ 90%（TypeProfileMajorReceiverPercent）
bool have_major_receiver = profile.has_receiver(0) && (100.*profile.receiver_prob(0) >= (float)TypeProfileMajorReceiverPercent);

// doCall.cpp:240 —— 接收者形态数（1=单态 2=双态 ≥3=多态）
int morphism = profile.morphism();

// doCall.cpp:261-269 —— 单态或双态 → 用头号接收者解析出具体方法
if (receiver_method == nullptr &&
    (have_major_receiver || morphism == 1 ||
     (morphism == 2 && UseBimorphicInlining))) {
  receiver_method = callee->resolve_invoke(jvms->method()->holder(), profile.receiver(0));
}
```

- `morphism == 1`：调用点只见过一个接收者 → **单态**，最理想
- `morphism == 2` + `UseBimorphicInlining`（默认开，c2_globals.hpp:475）：**双态**，可以内联两个方法
- 头号接收者占比 ≥ 90%：即使 morphism 大，也可以只赌头号

组装守卫（doCall.cpp:293-327）：

```cpp
// doCall.cpp:302-303 —— miss 路径：单态/双态 → uncommon trap（去优化撤退）
miss_cg = CallGenerator::for_uncommon_trap(callee, reason, Deoptimization::Action_maybe_recompile);
// 多态（morphism ≥ 3）→ miss 路径退回普通虚调用
miss_cg = CallGenerator::for_virtual_call(callee, vtable_index);

// doCall.cpp:322 —— 守卫菱形：预测接收者 k，命中走 hit_cg，miss 走 miss_cg
CallGenerator* cg = CallGenerator::for_predicted_call(k, miss_cg, hit_cg, hit_prob);
```

`PredictedCallGenerator::generate`（callGenerator.cpp:1070）生成一个**菱形 IR**：

```cpp
// callGenerator.cpp:1093-1099 —— 类型守卫
if (_exact_check) {
  slow_ctl = kit.type_check_receiver(receiver, _predicted_receiver, _hit_prob, &casted_receiver);
} else {
  slow_ctl = kit.subtype_check_receiver(receiver, _predicted_receiver, &casted_receiver);
}

// callGenerator.cpp:1106 —— miss 路径（撤退）
slow_jvms = _if_missed->generate(kit.sync_jvms());   // uncommon_trap 或虚调用

// callGenerator.cpp:1127 —— hit 路径（内联）
JVMState* new_jvms = _if_hit->generate(kit.sync_jvms());  // ParseGenerator 解析内联

// callGenerator.cpp:1159-1167 —— 汇合：Region(3) + Phi
RegionNode* region = new RegionNode(3);   // 菱形两臂汇合
region->init_req(1, kit.control());
region->init_req(2, slow_map->control());
kit.set_control(gvn.transform(region));
```

```
        receiver 类型检查
       /                \
   命中（hot，内联）    miss（cold）
   Parse 被调方法       uncommon_trap / 虚调用
       \                /
        └── Region(3) + Phi 汇合 ──┘
```

> 💡 **这就是"乐观优化"的编译期形态**：把概率最高的路径（头号接收者）内联成一条直线，小概率路径变成去优化陷阱。`Action_maybe_recompile` 表示：**撤太多次就重新编译，换一种策略**（比如放弃这个调用点的内联）。

## 十、路线 B：多态兜底与路线 C：直接调用

所有优化失败后的两条兜底路（doCall.cpp:397-419）：

```cpp
// doCall.cpp:399-407 —— 路线 B：还是多态 → 保留虚调用
if (call_does_dispatch) {
  if (IncrementalInlineVirtual && allow_inline) {
    return CallGenerator::for_late_inline_virtual(callee, vtable_index, prof_factor); // 以后补内联
  } else {
    return CallGenerator::for_virtual_call(callee, vtable_index);
  }
} else {
  // doCall.cpp:408-418 —— 路线 C：静态/特殊调用 → 直接调用 + receiver 约束守卫
  CallGenerator* cg = CallGenerator::for_direct_call(callee, should_delay_inlining(callee, jvms));
  if (cg != nullptr && is_virtual_or_interface && !callee->is_static()) {
    cg = CallGenerator::for_guarded_call(callee->holder(), trap_cg, cg);
  }
  return cg;
}
```

**VirtualCallGenerator**（callGenerator.cpp:225-324）生成 `CallDynamicJavaNode`——**把多态原样保留**，机器码层就是一个带内联缓存的虚调用（和解释器殊途同归，但用编译代码执行）：

```cpp
// callGenerator.cpp:296-303
assert(!method()->is_final(), "virtual call should not be to final");
assert(!method()->is_private(), "virtual call should not be to private");
address target = SharedRuntime::get_resolve_virtual_call_stub();
CallDynamicJavaNode* call = new CallDynamicJavaNode(tf(), target, method(), _vtable_index);
```

**DirectCallGenerator**（callGenerator.cpp:148-221）生成 `CallStaticJavaNode`——静态绑定目标，直接调：

```cpp
// callGenerator.cpp:186-193
address target = is_static ? SharedRuntime::get_resolve_static_call_stub()
                           : SharedRuntime::get_resolve_opt_virtual_call_stub();
CallStaticJavaNode* call = new CallStaticJavaNode(kit.C, tf(), target, method());
```

> 💡 **receiver 约束守卫**（doCall.cpp:413-416）：CHA 说"唯一实现"但接收者类型可能更宽（比如抽象类声明、default 方法丢类型信息）——所以直接调用前再包一层 `for_guarded_call`：**运行时确认 receiver 是目标方法持有者的子类**，不是就 uncommon_trap（`Reason_receiver_constraint`）。

## 十一、内联成本账：bytecodeInfo

要不要内联不是拍脑袋——`InlineTree`（bytecodeInfo.cpp）管这笔**成本账**，入口是 `ok_to_inline`：

```cpp
// bytecodeInfo.cpp:564-617（结构）
bool InlineTree::ok_to_inline(ciMethod* callee_method, JVMState* jvms, ciCallProfile& profile, bool& should_delay) {
  if (!pass_initial_checks(caller_method, caller_bci, callee_method))  return false;  // ① 基本检查
  set_msg(check_can_parse(callee_method));                            // ② 可解析性
  if (msg() != nullptr)  return false;
  bool success = try_to_inline(...);                                  // ③ 成本账
  ...
}
```

**① 可解析性**（check_can_parse，bytecodeInfo.cpp:531-539）——天生不能内联的：

```cpp
if (callee->is_native())             return "native method";
if (callee->is_abstract())           return "abstract method";
if (!callee->has_balanced_monitors()) return "not compilable (unbalanced monitors)";
if (callee->get_flow_analysis()->failing()) return "not compilable (flow analysis failed)";
if (!callee->can_be_parsed())        return "cannot be parsed";
```

**② 热度与大小**（should_inline，bytecodeInfo.cpp:116-193）——核心是**性价比**：

```cpp
// bytecodeInfo.cpp:160-164 —— 调用点热度 = 本调用点计数 / 方法总调用数
int call_site_count = caller_method->scale_count(profile.count());
int invoke_count = caller_method->interpreter_invocation_count();
double freq = (double)call_site_count / (double)invoke_count;

// bytecodeInfo.cpp:167-183 —— 热 → 放宽大小上限
if ((freq >= InlineFrequencyRatio /* 0.25，globals.hpp:1378 */) || ...) {
  max_inline_size = C->freq_inline_size();   // 热方法上限更大
} else {
  if (callee_method->has_compiled_code() &&
      callee_method->inline_instructions_size() > inline_small_code_size) {
    set_msg("already compiled into a medium method");
    return false;                            // 冷点 + 已有中等编译代码 → 不内联
  }
}

// bytecodeInfo.cpp:184-191 —— 大小裁决
if (size > max_inline_size) {
  set_msg("hot method too big");             // 或 "too big"
  return false;
}
```

**③ 深度/递归/累计**（try_to_inline，bytecodeInfo.cpp:364-491）：

```cpp
// :388-392 —— accessor（getter/setter）特例：无条件内联
if (InlineAccessors && callee_method->is_accessor()) {
  set_msg("accessor");
  return true;
}

// :430-441 —— 深度限制
if (inline_level() > _max_inline_level) {
  set_msg("inlining too deep");
  return false;
}

// :444-476 —— 递归检测（MaxRecursiveInlineLevel = 1，c2_globals.hpp:771）
// 沿 JVMS 调用链往上找：同一个方法出现 → 递归 → 太深拒绝

// :480-487 —— 累计大小（ClipInlining 时：已内联字节码总和 ≥ DesiredMethodLimit）
if (ClipInlining && (int)count_inline_bcs() + size >= DesiredMethodLimit) {
  set_msg("size > DesiredMethodLimit");
  return false;
}
```

**④ 两个强制内联入口**（should_inline 开头）：

```cpp
// bytecodeInfo.cpp:120-130
if (C->directive()->should_inline(callee_method)) { set_msg("force inline by CompileCommand"); return true; }
if (callee_method->force_inline())               { set_msg("force inline by annotation"); return true; }  // @ForceInline
```

> 💡 **内联深度的本质**：内联 = 把被调方法的字节码"展开"进调用者的 IR。展开一层，IR 就大一圈、编译时间就长一分。`DesiredMethodLimit`（ClipInlining 上限）是**整个方法的总预算**——所有内联目标累加，超了就停。这就是为什么"内联决策"本质是**收益（省调用）与成本（编译时间 + 代码膨胀）的账**。

## 十二、生成 IR 与收尾 + 四站闭环

决策结束，`cg->generate` 执行（doCall.cpp:721）：

```cpp
JVMState* new_jvms = cg->generate(jvms);
```

**ParseGenerator**（callGenerator.cpp:116-144）——内联的生成器：直接**重新解析被调方法的字节码**，展开进调用者 IR：

```cpp
// callGenerator.cpp:128 —— 内联 = 再来一个 Parse
Parse parser(jvms, method(), _expected_uses);
...
return exits.transfer_exceptions_into_jvms();
```

收尾两件事：

```cpp
// doCall.cpp:742-745 —— 内联了 → 通知环境（累计 has_loops 估值）
if (cg->is_inline()) {
  C->env()->notice_inlined_method(cg->method());
}

// doCall.cpp:762-765 —— 虚调用做了 null 检查 → 正常路径断言 receiver 非空
if (receiver != nullptr && cg->is_virtual()) {
  Node* cast = cast_not_null(receiver);
}
```

### 四站闭环

```
解释器（冷，跑一次）          解释器（热，每次跑）            C2（编译期，跑一次）
┌──────────────┐  写缓存   ┌──────────────┐  每次查表  ┌─────────────────────────┐
│ 01 linkResolver │ ───────▶│ RME 缓存     │ ─────────▶│ 04 doCall（本站）        │
│ 符号→Method*   │          │ 02 vtable 建表 │           │ CHA/profile 决策         │
└──────────────┘           └──────┬───────┘           │ → 内联 / 直接调 / 保留多态 │
                                  │                   └─────────────────────────┘
                                  │ profile_virtual_call（03 站 :3468）
                                  └──────────────────▶ MDO（类型档案，本站读取）
```

- **01 站**：冷路径解析，写缓存
- **02 站**：建 vtable/itable，分派表的内存形态
- **03 站**：热路径查表跳转，同时**顺手写 MDO**（`profile_virtual_call`）
- **04 站（本站）**：读 MDO 的类型档案 + 编译期 CHA，把"查表"优化成"不查表"

> 💡 **为什么这是最后一块拼图**：方法第一次跑 → 解释器解析（01）→ 每次调用查表（02/03）→ 跑热了 → C2 编译 → 用档案 + CHA 抹平调用（04）→ 变成直接调用/内联。**一条 invokevirtual 的一生**：从"每次查表"到"查一次，以后不查"。如果新类加载破坏 CHA 假设 → 依赖失效 → 撤销重编，回到解释器重新积累。整个系列四站，就是这条链的完整地图。

## 十三、行号速查表

| 内容 | 文件:行号 |
|---|---|
| Parse::do_call（编译期 invoke 入口） | opto/doCall.cpp:550 |
| 三问（is_virtual/has_receiver/will_link） | opto/doCall.cpp:557 / :564 / :579 |
| 初始化三件套（callee/vtable_index/call_does_dispatch） | opto/doCall.cpp:614 |
| Compile::call_generator（决策总闸） | opto/doCall.cpp:94 |
| 决策前读 profile（site_count/receiver_count） | opto/doCall.cpp:119 |
| intrinsic 优先（find_intrinsic） | opto/doCall.cpp:153 |
| 非多态 → ok_to_inline → for_inline | opto/doCall.cpp:198 / :202 |
| 类型 profile：have_major_receiver / morphism | opto/doCall.cpp:237 / :240 |
| for_predicted_call（守卫菱形组装） | opto/doCall.cpp:322 |
| CHA 接口单实现者（unique_implementor） | opto/doCall.cpp:346 / :358 |
| 多态兜底 for_virtual_call | opto/doCall.cpp:406 |
| 直接调用 for_direct_call + receiver 约束 | opto/doCall.cpp:410 |
| Compile::optimize_virtual_call（四连问入口） | opto/doCall.cpp:1169 |
| optimize_inlining：静态绑定优先 | opto/doCall.cpp:1203 |
| 数组 + Object 方法特例 | opto/doCall.cpp:1216 |
| CHA：find_monomorphic_target | opto/doCall.cpp:1238 |
| assert_unique_concrete_method（依赖记录） | opto/doCall.cpp:1250 |
| exact 类型直绑 | opto/doCall.cpp:1257 |
| cg->generate + notice_inlined_method + cast_not_null | opto/doCall.cpp:721 / :744 / :763 |
| Method::can_be_statically_bound（final 根源） | oops/method.cpp:876 |
| Method::is_final_method（final 类方法隐式 final） | oops/method.cpp:854 |
| ciMethod::can_be_statically_bound（private 修正） | ci/ciMethod.cpp:137 / :841 |
| ParseGenerator::generate（内联 = 重新解析） | opto/callGenerator.cpp:116 |
| DirectCallGenerator::generate（CallStaticJavaNode） | opto/callGenerator.cpp:183 |
| VirtualCallGenerator::generate（CallDynamicJavaNode） | opto/callGenerator.cpp:254 |
| PredictedCallGenerator::generate（守卫菱形） | opto/callGenerator.cpp:1070 |
| for_predicted_call / for_guarded_call | opto/callGenerator.cpp:1055 / :1063 |
| InlineTree::ok_to_inline（内联总入口） | opto/bytecodeInfo.cpp:564 |
| check_can_parse（可解析性） | opto/bytecodeInfo.cpp:531 |
| should_inline（热度/大小账） | opto/bytecodeInfo.cpp:116 |
| try_to_inline（深度/递归/累计） | opto/bytecodeInfo.cpp:364 |
| TypeProfileMajorReceiverPercent = 90 | opto/c2_globals.hpp:700 |
| UseBimorphicInlining = true | opto/c2_globals.hpp:475 |
| MaxRecursiveInlineLevel = 1 | opto/c2_globals.hpp:771 |
| MaxTrivialSize = 6 | opto/c2_globals.hpp:790 |
| InlineFrequencyRatio = 0.25 | share/runtime/globals.hpp:1378 |
| InlineThrowCount / InlineThrowMaxSize = 50 / 200 | share/runtime/globals.hpp:1385 / :1389 |
