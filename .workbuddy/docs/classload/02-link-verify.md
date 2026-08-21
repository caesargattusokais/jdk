# 类加载站②：链接三阶段——验证 / 链接 / 准备与解析

> 站①（加载与双亲委派）把 .class 字节流送到了 `KlassFactory`，工匠雕出了 `InstanceKlass` 骨架。
> 这一站讲骨架「通电」的过程：JVM 规范把类加载的第 2/3/4 步统称**链接（Linking）**，分**验证 → 准备 → 解析**三个阶段；
> HotSpot 的实现在规范之上还多了一道自己特有的「链接（link_class）」工序——把方法入口、vtable/itable 全部接好线。
> 本文锚点全部来自 JDK 28 mainline（`src/hotspot/share/`），行号可对照源码逐行核对。

---

## 快速概览

- **一句话**：链接 = 「体检（验证）→ 铺好静态字段默认值（准备）→ 把符号引用换成真身（解析）」，HotSpot 中间还插了「接线（rewrite + vtable/itable）」，接线完成才 `set_init_state(linked)`。
- **白话比喻**：加载是「招人进公司」，链接是「入职培训」——先体检（验证字节码），再领工位和默认装备（静态字段默认值），最后把花名册上的「岗位名」逐个对上真人（符号引用解析）。
- **两个「链接」要分清**：JVM 规范的 **Linking（链接）** 是加载后的三个阶段总称；HotSpot 的 **link_class（instanceKlass.cpp:1106）** 只是其中一道工序（验证之后、初始化之前）。
- **核心结论**：HotSpot 把「解析（resolution）」做成了**懒加载**——不在链接期一口气做完，而是第一次用到某个符号时现解析（常量池站②的 `klass_at_impl` / `resolve_invoke` 就是现场解析）；链接期真正做完的是**验证 + 字节码改写 + 方法入口 + vtable/itable**。

**关键源码入口**

| 阶段 | 函数 | 位置 |
|---|---|---|
| 解析（读 .class 结构） | `ClassFileParser::parse_stream` | classFileParser.cpp:6024 |
| 魔数校验 | `guarantee_property(magic == JAVA_CLASSFILE_MAGIC)` | classFileParser.cpp:6034 |
| 版本校验 | `verify_class_version` | classFileParser.cpp:6043 |
| 验证 | `InstanceKlass::verify_code` | instanceKlass.cpp:1063 |
| 验证（实现） | `Verifier::verify` | verifier.cpp:183 |
| 链接（HotSpot 工序） | `InstanceKlass::link_class_impl` | instanceKlass.cpp:1123 |
| 字节码改写 | `InstanceKlass::rewrite_class` | instanceKlass.cpp:1296 |
| 方法入口接线 | `InstanceKlass::link_methods` | instanceKlass.cpp:1309 |
| vtable 填充 | `klassVtable::initialize_vtable_and_check_constraints` | klassVtable.cpp:615 |
| itable 填充 | `klassItable::initialize_itable_and_check_constraints` | klassVtable.cpp:1223 |
| 准备（静态字段默认值） | `InstanceKlass::allocate_instance_klass` | instanceKlass.cpp:522 |
| 解析（懒加载） | `ConstantPool::klass_at_impl` | constantPool.cpp:631（常量池站②） |

---

## TOC

1. [从加载到链接：一条流水线的四道工序](#1-从加载到链接一条流水线的四道工序)
2. [关卡① 解析（parse）：验明正身——魔数、版本、常量池](#2-关卡①-解析parse验明正身魔数版本常量池)
3. [关卡② 验证（verify）：字节码体检](#3-关卡②-验证verify字节码体检)
4. [关卡③ 链接（link）：HotSpot 的接线工序](#4-关卡③-链接linkhotspot-的接线工序)
5. [关卡④ 准备与解析（prepare & resolve）：默认值与懒解析](#5-关卡④-准备与解析prepare--resolve默认值与懒解析)
6. [JVM 规范 vs HotSpot 实现：术语对照](#6-jvm-规范-vs-hotspot-实现术语对照)
7. [与站①③衔接：加载 → 链接 → 初始化](#7-与站①③衔接加载--链接--初始化)
8. [行号速查](#8-行号速查)

---

## 1. 从加载到链接：一条流水线的四道工序

类加载（JVM 规范视角）分五步：**加载 → 验证 → 准备 → 解析 → 初始化**，其中第 2-4 步合称**链接**。站①覆盖「加载」，站②覆盖「链接」（验证/准备/解析），站③覆盖「初始化」。

但 HotSpot 的实际实现顺序和规范术语并不一一对应——它把「解析」拆成了两半：

- **结构性解析（parse）**：`ClassFileParser::parse_stream` 在读字节流时就完成了——魔数、版本、常量池、字段、方法全在 `create_instance_klass` 之前解析完（站①已经走完这一步）。
- **符号解析（resolution）**：类文件里的 `Class` / `Methodref` / `Fieldref` 符号引用，HotSpot **不**在链接期集中解析，而是第一次使用时才解析（常量池站②的 `klass_at_impl`、`resolve_invoke`）。所以 JVM 规范的「解析」阶段在 HotSpot 里是**撒在运行期**的。

而 HotSpot 多出来的「link_class」工序（规范里没有的名字）做的是：**验证字节码 → 改写字节码 → 接方法入口 → 填 vtable/itable**——这些在 JVM 规范里被算作「验证/准备」的延伸，但在 HotSpot 代码里是独立的一道门（`is_linked()` 状态）。

> **记法**：HotSpot 的流水线是「parse（读结构）→ verify（体检）→ link（接线）→ initialize（通电）」，符号解析（resolution）是运行期懒做的一步，不算在 link 门内。

---

## 2. 关卡① 解析（parse）：验明正身——魔数、版本、常量池

站①的 `KlassFactory::create_from_stream`（klassFactory.cpp:172）构造 `ClassFileParser` 后调用 `parse_stream`（classFileParser.cpp:6024）。这一步做的第一件事不是建类，而是**验明正身**——确认拿到的确实是合法的 class 文件。

```cpp
// classFileParser.cpp:6024
void ClassFileParser::parse_stream(const ClassFileStream* const stream, TRAPS) {
  // BEGIN STREAM PARSING
  stream->guarantee_more(8, CHECK);  // magic, major, minor      :6031
  // Magic value
  const u4 magic = stream->get_u4_fast();                        // :6033
  guarantee_property(magic == JAVA_CLASSFILE_MAGIC,              // :6034
                     "Incompatible magic value %u in class file %s",
                     magic, CHECK);
  // Version numbers
  _minor_version = stream->get_u2_fast();                        // :6039
  _major_version = stream->get_u2_fast();                        // :6040
  verify_class_version(_major_version, _minor_version, _class_name, CHECK);  // :6043
  ...
  _cp = ConstantPool::allocate(_loader_data, cp_size, CHECK);    // :6058
  parse_constant_pool(stream, cp, _orig_cp_size, CHECK);         // :6064
```

**三个验明正身的动作**：

1. **魔数校验（:6033-6036）**：class 文件头 4 字节必须是 `0xCAFEBABE`（宏定义在 :101）。不是就抛 `ClassFormatError`——「这不是一个合法的 class 文件」。
2. **版本校验（:6039-6043）**：接下来 2+2 字节是小/大版本号，`verify_class_version` 检查大版本是否超过当前 JVM 支持上限——超过抛 `UnsupportedClassVersionError`（「用新 JDK 编的类跑在旧 JVM 上」就是这个错误）。
3. **常量池结构解析（:6058-6064）**：`ConstantPool::allocate` 按 `cp_size` 建运行时常量池，`parse_constant_pool` 逐项读入（这就是常量池站①讲的 #12 条目原始形态）。

> **为什么这算「链接」的起点**：JVM 规范把结构解析归在「加载」，但 HotSpot 中 `parse_stream` 产出的 `InstanceKlass` 要到 `link_class` 才可执行——所以从「可以用」的角度看，parse 是链接的前置。

---

## 3. 关卡② 验证（verify）：字节码体检

`InstanceKlass` 骨架造好后，第一道正式工序是**验证（verification）**——检查字节码没有安全漏洞、类型错误。入口在 `link_class_impl` 内部（instanceKlass.cpp:1218），实现在 verifier.cpp。

```cpp
// instanceKlass.cpp:1218（link_class_impl 内部）
bool verify_ok = verify_code(THREAD);
if (!verify_ok) {
  return false;
}
```

```cpp
// instanceKlass.cpp:1063
bool InstanceKlass::verify_code(TRAPS) {
  // 1) Verify the bytecodes
  return Verifier::verify(this, should_verify_class(), THREAD);
}
```

**Verifier::verify（verifier.cpp:183）的三道检查**：

1. **准入检查（:199）**：`is_eligible_for_verification`（verifier.cpp:136-147）——如果 JVM 配置为跳过验证（`-Xverify:none`），或该类已从 AOT 缓存加载且已改写（共享类已被验证过），直接放行返回 true。
2. **分裂验证器（split verifier，:222-225）**：版本 ≥ StackMap 时代的类（JDK 6+）走 `ClassVerifier`——按方法的字节码逐条做**类型检查**，校验操作数栈和局部变量的类型流，依赖 class 文件里的 **StackMapTable**（栈映射帧）属性。
3. **回退验证器（inference verifier，:248）**：老版本类没有 StackMap，用 `inference_verify` 做数据流推断；新版本类验证失败且 `-XX:FailOverToOldVerifier` 允许时也会回退。

**失败后果**：验证不通过 → 抛 `VerifyError`（instanceKlass.cpp:1219 返回 false，link 中断，类留在 `in_error_state`）。

> **白话**：验证 = 「入职体检」。体检不过直接淘汰（VerifyError），体检通过才允许进下一步——因为字节码可以不经过 javac，手写或工具生成的非法字节码必须在这里被拦下，否则解释器/JIT 可能执行类型不安全代码。

---

## 4. 关卡③ 链接（link）：HotSpot 的接线工序

这是 HotSpot **独有的**一道门（JVM 规范没有这个名字），也是 `is_linked()` 状态的来源。完整流程在 `link_class_impl`（instanceKlass.cpp:1123）：

```cpp
// instanceKlass.cpp:1123
bool InstanceKlass::link_class_impl(TRAPS) {
  ...
  // ① 先链接父类，再链接接口（递归，深度优先）      :1150-1174
  InstanceKlass* super_klass = super();
  if (super_klass != nullptr) {
    ...
    super_klass->link_class_impl(CHECK_false);                 // :1165
  }
  for (int index = 0; index < num_interfaces; index++) {
    interk->link_class_impl(CHECK_false);                      // :1173
  }
  ...
  // ② 加 init_lock 互斥，防并发重复链接                 :1200-1205
  ObjectLocker ol(h_init_lock, CHECK_PREEMPTABLE_false);
  NoPreemptMark npm(THREAD);
  ...
  if (!is_linked()) {
    if (!is_rewritten()) {
      bool verify_ok = verify_code(THREAD);                    // :1218 验证（关卡②）
      ...
      rewrite_class(CHECK_false);                              // :1232 改写字节码
    }
    link_methods(CHECK_false);                                 // :1238 接方法入口
    ...
    vtable().initialize_vtable_and_check_constraints(CHECK_false);  // :1256
    itable().initialize_itable_and_check_constraints(CHECK_false);  // :1257
    ...
    set_init_state(linked);                                    // :1271/:1277 标记已链接
    JvmtiExport::post_class_prepare(THREAD, this);             // :1279 JVMTI 回调
  }
  return true;
}
```

**接线四小步**：

1. **先父后己（:1150-1174）**：链接子类前，父类和接口必须已经链接（递归 `link_class_impl`）——保证 vtable 继承关系成立。若父类是接口（`extends` 了一个 interface）抛 `IncompatibleClassChangeError`（:1155-1162）。
2. **字节码改写 rewrite_class（:1232 → :1296）**：`Rewriter::rewrite`（:1302）把字节码里的常量池索引改写为**常量池缓存索引**（`invokevirtual #12` → 指向 ConstantPoolCache 条目——方法调用站讲过的「小本本」），jsr/ret 重定位等。**改写只做一次**（:1298 `is_rewritten()` 防重入）。
3. **方法入口接线 link_methods（:1238 → :1309）**：对每个 `Method` 调 `m->link_method`（:1317）——决定这个方法用解释器还是 C2/JIT 入口（第一次执行还是解释器，见方法调用站⑤）。
4. **填 vtable/itable（:1256-1257）**：`initialize_vtable_and_check_constraints`（klassVtable.cpp:615）/ `initialize_itable_and_check_constraints`（klassVtable.cpp:1223）——按继承层次填方法分发表（方法调用站②讲过的「员工名册」），同时做**加载器约束检查**（父子加载器对同一个类的解析必须一致）。

**完成标志**：`set_init_state(linked)`（:1271/:1277）——之后 `is_linked()` 返回 true，类才算「可以用」。

> **白话**：链接 = 「接线」。把花名册填好（vtable/itable）、把每部电话接上分机（方法入口）、把标签换成内线号码（常量池缓存索引）。这一道门做完，类才从「档案」变成「可上岗员工」。

---

## 5. 关卡④ 准备与解析（prepare & resolve）：默认值与懒解析

JVM 规范的「准备」和「解析」在 HotSpot 里都**不是** `link_class_impl` 里的显式步骤，而是两个分散的实现：

### 5.1 准备（prepare）：静态字段内存与默认值

规范要求：链接期给静态字段分配内存并设**默认值**（0 / null / false），真正的赋值留给 `<clinit>`（初始化阶段）。

HotSpot 的做法：静态字段内存是 `InstanceKlass` 对象布局的一部分，在 `allocate_instance_klass`（instanceKlass.cpp:522）分配时就**一次性算好并清零**：

```cpp
// instanceKlass.cpp:522
InstanceKlass* InstanceKlass::allocate_instance_klass(const ClassFileParser& parser, TRAPS) {
  const int size = InstanceKlass::size(parser.vtable_size(),
                                       parser.itable_size(),
                                       nonstatic_oop_map_size(parser.total_oop_map_count()),
                                       parser.is_interface(),
                                       parser.is_inline_type());      // :523-527
  ...
  ik = new (loader_data, size, THREAD) InstanceKlass(parser);         // :554
```

- `size` 计算包含 `parser.static_field_size()`（classFileParser.cpp:5194）——静态字段区**就长在 InstanceKlass 对象后面**。
- Metaspace 分配内存默认清零 = 规范要求的「默认值」。
- 所以静态字段的「准备」在站①的 `create_instance_klass`（classFileParser.cpp:5304 → :5312）就顺带完成了，`link_class` 阶段不再重复。

### 5.2 解析（resolve）：符号引用 → 直接引用（懒加载）

规范要求：把常量池里的符号引用（`Dog`、`Dog.bark:()V`）解析为直接引用（真身）。

HotSpot 的做法：**不集中解析**，而是**用到的瞬间才解析**（lazy），且解析结果缓存在 `ConstantPoolCache` / `_resolved_klasses`——这正是常量池站②的全部分内容：

| 符号引用 | 首次使用触发点 | 位置 |
|---|---|---|
| 类 `Class` | `ConstantPool::klass_at_impl` | constantPool.cpp:631 |
| 方法 `Methodref` | `InterpreterRuntime::resolve_invoke` | interpreterRuntime.cpp:864 |
| 字段 `Fieldref` | `InterpreterRuntime::resolve_from_cache` 分支 | interpreterRuntime.cpp:1063 |

**为什么懒**：类可能永远用不到某个符号（比如异常路径里的类），链接期全解析既慢又可能误报 `NoClassDefFoundError`。懒解析 + 缓存 = 只付一次钱。

> **白话**：准备 = 「工位配默认装备」（内存清零）；解析 = 「用到谁才查谁的档案」（懒汉式）。

---

## 6. JVM 规范 vs HotSpot 实现：术语对照

| JVM 规范阶段 | HotSpot 实际对应 | 关键位置 |
|---|---|---|
| 加载 Loading | `ClassLoader::load_class` → `KlassFactory::create_from_stream` → `parse_stream` | classLoader.cpp:1100 / klassFactory.cpp:172 / classFileParser.cpp:6024 |
| 验证 Verification | `verify_code` → `Verifier::verify`（split verifier + inference failover） | instanceKlass.cpp:1063 / verifier.cpp:183 |
| 准备 Preparation | 静态字段内存随 `InstanceKlass` 分配并清零 | instanceKlass.cpp:522 / classFileParser.cpp:5194 |
| 解析 Resolution | **懒解析**：首次使用时 `klass_at_impl` / `resolve_invoke`，结果缓存 | constantPool.cpp:631 / interpreterRuntime.cpp:864 |
| （规范外）HotSpot 特有 | `link_class_impl`：rewrite + link_methods + vtable/itable + 置 linked 状态 | instanceKlass.cpp:1123 |
| 初始化 Initialization | `InstanceKlass::initialize` → `<clinit>` | instanceKlass.cpp:961（站③） |

**两个易混点**：

1. **「链接」与「link_class」不是一回事**：规范的 Linking = 验证+准备+解析三阶段总称；HotSpot 的 `link_class` 是验证之后、初始化之前的一道门（改写+接线），规范的「解析」被拆到运行期了。
2. **「解析」有两个**：`parse_stream` 的结构解析（读 class 文件布局）发生在加载期；符号解析（resolution）发生在运行期首次使用。文档中一律用「结构解析/parse」和「符号解析/resolve」区分。

---

## 7. 与站①③衔接：加载 → 链接 → 初始化

```
站① 加载（load）              站② 链接（link）              站③ 初始化（initialize）
┌─────────────────────┐   ┌─────────────────────────┐   ┌──────────────────────┐
│ loadClass 双亲委派   │   │ parse 验明正身（魔数/版本）│   │ initialize :961      │
│  ↓                  │   │ verify 字节码体检        │   │  ↓                  │
│ JVM_DefineClass     │   │ rewrite 字节码改写       │   │ 运行 <clinit>        │
│  ↓                  │   │ link_methods 方法入口    │   │ 静态字段真正赋值      │
│ KlassFactory 雕骨架  │   │ vtable/itable 填名册     │   │ set_init_state(init) │
│  ↓                  │   │ set_init_state(linked)  │   │  ↓                  │
│ InstanceKlass 诞生   │──→│ （is_linked = true）    │──→│ 类真正可「用」       │
└─────────────────────┘   └─────────────────────────┘   └──────────────────────┘
```

- **站①→站②**：`link_class` 要求 `is_loaded()`（instanceKlass.cpp:1107 断言），所以必须先完成加载。
- **站②→站③**：`initialize`（instanceKlass.cpp:961）要求 `is_linked()`——只有链接完成（vtable/itable 就绪）才能跑 `<clinit>`，因为 `<clinit>` 里可能调用本类方法，需要 vtable 已就位。

---

## 8. 行号速查

| 函数/动作 | 文件:行号 |
|---|---|
| `ClassFileParser::parse_stream`（结构解析总入口） | classFileParser.cpp:6024 |
| 魔数校验 `0xCAFEBABE` | classFileParser.cpp:6034（宏 :101） |
| 版本校验 `verify_class_version` | classFileParser.cpp:6043 |
| 常量池分配/解析 | classFileParser.cpp:6058 / :6064 |
| `ClassFileParser::static_field_size` | classFileParser.cpp:5194 |
| `InstanceKlass::allocate_instance_klass`（静态字段内存） | instanceKlass.cpp:522 |
| `InstanceKlass::verify_code` | instanceKlass.cpp:1063 |
| `InstanceKlass::link_class`（入口，防重入） | instanceKlass.cpp:1106 |
| `InstanceKlass::link_class_or_fail`（不抛错版） | instanceKlass.cpp:1115 |
| `InstanceKlass::link_class_impl`（核心流程） | instanceKlass.cpp:1123 |
| 先链接父类（递归） | instanceKlass.cpp:1150-1166 |
| 再链接接口（递归） | instanceKlass.cpp:1168-1174 |
| init_lock 加锁 | instanceKlass.cpp:1200-1205 |
| 调用 `verify_code`（验证） | instanceKlass.cpp:1218 |
| 调用 `rewrite_class`（改写） | instanceKlass.cpp:1232 |
| 调用 `link_methods`（方法入口） | instanceKlass.cpp:1238 |
| vtable/itable 填充 | instanceKlass.cpp:1256-1257 |
| `set_init_state(linked)` | instanceKlass.cpp:1271 / :1277 |
| JVMTI `post_class_prepare` 回调 | instanceKlass.cpp:1279-1281 |
| `InstanceKlass::rewrite_class` | instanceKlass.cpp:1296 |
| `Rewriter::rewrite` | instanceKlass.cpp:1302 |
| `InstanceKlass::link_methods` | instanceKlass.cpp:1309 |
| `Method::link_method`（方法入口点） | instanceKlass.cpp:1317 |
| `Verifier::verify`（验证实现） | verifier.cpp:183 |
| 准入检查 `is_eligible_for_verification` | verifier.cpp:136-147 |
| split verifier `ClassVerifier` | verifier.cpp:222-225 |
| inference verifier 回退 | verifier.cpp:248 |
| `klassVtable::initialize_vtable_and_check_constraints` | klassVtable.cpp:615 |
| `klassItable::initialize_itable_and_check_constraints` | klassVtable.cpp:1223 |
| `ConstantPool::klass_at_impl`（懒解析类） | constantPool.cpp:631（常量池站②） |
| `InterpreterRuntime::resolve_invoke`（懒解析方法） | interpreterRuntime.cpp:864（常量池站②） |
| `InstanceKlass::initialize`（站③预告） | instanceKlass.cpp:961 |

> 下一站：**类加载站③ 初始化与卸载**——`<clinit>` 如何触发、`initialize`（instanceKlass.cpp:961）如何加锁防并发、初始化失败的错误表、以及类卸载与 `ClassLoaderData` 的回收。
