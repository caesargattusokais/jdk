# 声明域 + 访问控制 + module：class 文件头部的一本账

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Java 关键字源码跟读 · 第 10 篇（收官，[回到系列索引](README.md)）
> 前置：[09 控制流与字面量](09-control-flow-and-literals.md)

---

## 快速概览

- **一句话结论**：本批 20+ 个"关键字"的落点高度集中——**全部是 class 文件头部（access_flags + 属性表 + 常量池引用）的一本账**：
  1. **声明域**（`class/interface/enum/record/abstract/sealed/permits/extends/implements`）→ 全部编码进 **access_flags u2** + 父类/接口索引 + 专属属性（`Record`、`PermittedSubclasses`）；
  2. **访问控制**（`public/protected/private`）→ 也是 access_flags 的 3 个位，但**运行期零强制**（加载期只做互斥校验，访问检查全部在 javac/反射层）；`package`/`import` → **零字节码零属性**；`transient` → 标志存在但 **VM 无机制**（`accessFlags.hpp:57` 只存位，序列化跳过是 Java 层的事）；
  3. **module 系**（`module/requires/exports/opens/uses/provides/with`）→ 只有 `module` 是 class 文件关键字：`module-info.class` 是 **ACC_MODULE 特殊类**（`classFileParser.cpp:4492`），**解析不在 HotSpot**——在 java.base 的 `jdk.internal.module.ModuleInfo`（Java 层），HotSpot 只收 `JVM_DefineModule`（`jvm.cpp:1316`）建 `ModuleEntry`；`requires/exports/...` 连 Java 关键字都不是（JLS 的 restricted keywords，只在 module-info 上下文生效）。
- **JDK 28 最大意外**：教科书里的 `ACC_SUPER` 变成了 **`JVM_ACC_IDENTITY`**（`jvm_constants.h:33`）——Valhalla 把"super 标志位"重定义为"identity class 标志位"，普通类自动带 identity 语义。
- **系列收官**：从 01 全景的 50 关键字 7 域地图出发，02-10 共 9 篇深读全部落位——**每个关键字要么链到 HotSpot 机制，要么链到 javac 语义，要么被证明"class 文件零痕迹"**。

---

## 目录

1. [本批"关键字"全景：落点集中在 class 头部](#一本批关键字全景落点集中在-class-头部)
2. [access_flags：一个 u2 承载所有声明关键字](#二access_flags一个-u2-承载所有声明关键字)
3. [四种声明形态：class/interface/enum/record](#三四种声明形态classinterfaceenumrecord)
4. [extends/implements：父类与接口索引](#四extendsimplements父类与接口索引)
5. [abstract/sealed/permits：类间关系的修饰](#五abstractsealedpermits类间关系的修饰)
6. [public/protected/private：只有位没有兵](#六publicprotectedprivate只有位没有兵)
7. [package/import：零字节码的双子](#七packageimport零字节码的双子)
8. [transient：标志活着，机制死了](#八transient标志活着机制死了)
9. [module-info.class：解析路径与 ACC_MODULE](#九module-infoclass解析路径与-acc_module)
10. [module 指令们：requires/exports/opens/uses/provides/with](#十module-指令们requiresexportsopensusesprovideswith)
11. [JDK 28 vs 教科书差异](#十一jdk-28-vs-教科书差异)
12. [验证实验](#十二验证实验)
13. [系列收官：50 关键字的最终分布](#十三系列收官50-关键字的最终分布)

---

## 一、本批"关键字"全景：落点集中在 class 头部

| 类别 | 关键字 | class 文件落点 | 运行期机制 | 核心锚点 |
|---|---|---|---|---|
| **声明域** | `class/interface/enum/record` | access_flags 对应位 + 属性 | 类形态决定链接/分派语义 | `classFileParser.cpp:4507-4511` |
| 声明域 | `abstract` | `ACC_ABSTRACT` | 禁止实例化（new 检查） | `classFileParser.cpp:4508` |
| 声明域 | `sealed/permits` | `ACC_SEALED` + `PermittedSubclasses` 属性 | 加载期子类校验 | `classFileParser.cpp:3233` |
| 声明域 | `extends/implements` | super_class 索引 + interfaces 数组 | 链接期构建继承链 | `classFileParser.cpp:4005` |
| **访问控制** | `public/protected/private` | access_flags 3 位 | **运行期零强制**（仅互斥校验） | `classFileParser.cpp:4551` |
| 访问控制 | `package` | 并入全限定名 | 包/模块归属（`Package`/`ModuleEntry`） | `moduleEntry.cpp` |
| 访问控制 | `import` | **零痕迹** | 无（纯 javac 名字解析） | — |
| 访问控制 | `transient` | `ACC_TRANSIENT` | **VM 无机制**（仅反射可见） | `accessFlags.hpp:57` |
| **module 系** | `module` | `ACC_MODULE` + `Module` 属性 | **Java 层解析** + `JVM_DefineModule` | `jvm.cpp:1316` |
| module 系 | `requires/exports/opens/uses/provides/with` | Module 属性内表项 | ModuleDescriptor 内部表 | `ModuleInfo.java` |

> 全景结论：**声明与访问控制 = class 文件头部的账本**。`import` 是全系列唯一"连账本都不记"的关键字——javac 编译完直接丢弃。

## 二、access_flags：一个 u2 承载所有声明关键字

### 2.1 三组识别掩码（jvm_constants.h:31-62）

class 文件里 `access_flags` 是 **2 字节**，JDK 用三组掩码区分"哪些位对类/字段/方法合法"：

```cpp
#define JVM_RECOGNIZED_CLASS_MODIFIERS (JVM_ACC_PUBLIC | \
                                        JVM_ACC_FINAL | \
                                        JVM_ACC_IDENTITY | \    // ← 教科书叫 ACC_SUPER！
                                        JVM_ACC_INTERFACE | \
                                        JVM_ACC_ABSTRACT | \
                                        JVM_ACC_ANNOTATION | \
                                        JVM_ACC_ENUM | \
                                        JVM_ACC_SYNTHETIC)

#define JVM_RECOGNIZED_FIELD_MODIFIERS  (JVM_ACC_PUBLIC | ... | JVM_ACC_TRANSIENT | JVM_ACC_ENUM | ...)
#define JVM_RECOGNIZED_METHOD_MODIFIERS (JVM_ACC_PUBLIC | ... | JVM_ACC_ABSTRACT | JVM_ACC_STRICT | ...)
```

三个细节：

1. **类掩码没有 PRIVATE/PROTECTED**——顶层类不能 private/protected，javac 在源码层就拦了，class 文件层根本不认；
2. **字段掩码有 TRANSIENT/ENUM，没有 ABSTRACT/INTERFACE**——字段的合法位集合与类/方法完全不同，`parse_classfile_attributes` 按掩码过滤非法标志；
3. **`JVM_ACC_IDENTITY` 是 JDK 28 的名字**——老版本叫 `ACC_SUPER`（0x0020），Valhalla 重定义为"identity class"标记，普通类编译时 javac 总会带上。

### 2.2 标志位一览（classfile_constants.h 取值）

| 位 | 值 | 类 | 字段 | 方法 |
|---|---|---|---|---|
| PUBLIC | 0x0001 | ✅ | ✅ | ✅ |
| PRIVATE | 0x0002 | — | ✅ | ✅ |
| PROTECTED | 0x0004 | — | ✅ | ✅ |
| STATIC | 0x0008 | — | ✅ | ✅ |
| FINAL | 0x0010 | ✅ | ✅ | ✅ |
| IDENTITY(SUPER) | 0x0020 | ✅ | — | — |
| SYNCHRONIZED | 0x0020 | — | — | ✅ |
| VOLATILE | 0x0040 | — | ✅ | — |
| BRIDGE | 0x0040 | — | — | ✅ |
| TRANSIENT | 0x0080 | — | ✅ | — |
| VARARGS | 0x0080 | — | — | ✅ |
| NATIVE | 0x0100 | — | — | ✅ |
| INTERFACE | 0x0200 | ✅ | — | — |
| ABSTRACT | 0x0400 | ✅ | — | ✅ |
| STRICT | 0x0800 | — | — | ✅ |
| SYNTHETIC | 0x1000 | ✅ | ✅ | ✅ |
| ANNOTATION | 0x2000 | ✅ | — | — |
| ENUM | 0x4000 | ✅ | ✅ | — |
| MODULE | 0x8000 | ✅ | — | — |
| RECORD | 0x10000 | ✅ | — | — |
| SEALED | 0x20000 | ✅ | — | — |

> 注意 **位复用**：0x0020 在类上是 IDENTITY、在方法上是 SYNCHRONIZED；0x0040 在字段上是 VOLATILE、在方法上是 BRIDGE；0x0080 在字段上是 TRANSIENT、在方法上是 VARARGS——**同一个位在不同上下文含义不同**，这就是为什么必须按 `JVM_RECOGNIZED_*` 三组掩码分开校验。

## 三、四种声明形态：class/interface/enum/record

### 3.1 形态 = 标志组合（classFileParser.cpp:4507-4511）

```cpp
const bool is_interface  = (flags & JVM_ACC_INTERFACE)  != 0;
const bool is_abstract   = (flags & JVM_ACC_ABSTRACT)   != 0;
const bool is_final      = (flags & JVM_ACC_FINAL)      != 0;
const bool is_identity   = (flags & JVM_ACC_IDENTITY)   != 0;
const bool is_enum       = (flags & JVM_ACC_ENUM)       != 0;
const bool is_annotation = (flags & JVM_ACC_ANNOTATION) != 0;
```

| Java 声明 | 标志组合 | 说明 |
|---|---|---|
| `class C` | IDENTITY（+可能 FINAL/ABSTRACT） | 普通类 |
| `interface I` | INTERFACE + ABSTRACT | 接口自动带 ABSTRACT（老版本自动补，:3151） |
| `@interface A` | INTERFACE + ABSTRACT + ANNOTATION | 注解是"接口 + ANNOTATION 位" |
| `enum E` | FINAL + ENUM | 枚举是"final 类 + ENUM 位" |
| `record R` | FINAL + RECORD + Record 属性 | 记录是"final 类 + RECORD 位" |

**合法性校验**（:4516-4520）：`is_abstract && is_final` 非法；`is_interface && !is_abstract` 非法；接口不能是 enum/identity——**四种形态本质上是标志位的合法组合**。

### 3.2 record：Record 属性（parse_classfile_record_attribute :3322）

```cpp
//  Record {
//      u2 attributes_count;
//      record_component_info components[attributes_count];
//  }
u4 ClassFileParser::parse_classfile_record_attribute(...)   // :3322
```

`ACC_RECORD`（0x10000）+ `Record` 属性（组件列表：名称/描述符/属性）。**记录组件会被 javac 合成出字段 + 构造器 + accessor**，但 VM 只负责存组件元数据供反射（`RecordComponent`）——语言语义全在 javac。

### 3.3 enum：ACC_ENUM 与合成方法

`ACC_ENUM`（0x4000）在类上是"这是枚举"，在字段上是"这是枚举常量"。javac 把 `enum E` 编译成 `final class E extends Enum<E>` + 合成 `values()`/`valueOf()`（`java.lang.Enum` 的私有构造器防扩展）——**ENUM 位只服务于反射（`Class.isEnum()`）**，运行期机制在 Enum 基类。

## 四、extends/implements：父类与接口索引

### 4.1 class 文件布局（check_super_class :4005）

```
ClassFile {
    u4 magic; u2 minor; u2 major;
    u2 constant_pool_count; cp_info constant_pool[];   // 常量池
    u2 access_flags;
    u2 this_class;         // → 常量池 Class 索引
    u2 super_class;        // → 父类（0 = Object / 接口）
    u2 interfaces_count;   // → 直接实现的接口数
    u2 interfaces[];       // → 直接实现的接口
    ...
}
```

- **`extends`** → `super_class` 一个 u2 索引；**`implements`** → `interfaces` 数组（多个）；
- `check_super_class`（:4005）校验父类索引合法性（非数组类、非 final 类等）；`check_super_class_access`（:4289）校验访问（子类必须能访问父类）；
- 运行期：`initialize_supers`（:5663）构建继承链（`_super_klass` + `_transitive_interfaces` 传递闭包）——**instanceof（06 篇）的 super_check 就在这条链上跑**。

### 4.2 继承链与 06 篇闭环

`extends/implements` 在 class 文件里只是索引，**真正的工作在链接期**：`InstanceKlass::initialize_supers` 把父类和所有传递接口整理成子类型检查要用的结构（`_secondary_supers`）——06 篇的 `check_klass_subtype` 快路径查的就是这份整理结果。**声明关键字的运行期生命 = 构建 06 篇的数据结构**。

## 五、abstract/sealed/permits：类间关系的修饰

### 5.1 abstract：ACC_ABSTRACT 与实例化禁令

`ACC_ABSTRACT`（0x0400）类不能 `new`——解释器/C2 的 `new` 模板在分配前查 `Klass::is_abstract()`，抽象类直接 `AbstractMethodError` 路径（衔接 04 篇）。接口自动带 ABSTRACT（:3151 老版本兼容补位）。

### 5.2 sealed：ACC_SEALED + PermittedSubclasses（JEP 409）

```cpp
u2 ClassFileParser::parse_classfile_permitted_subclasses_attribute(...)  // :3233
```

- 编译期：javac 把 `sealed` 编译成 **`ACC_SEALED`**（0x20000）+ **`PermittedSubclasses` 属性**（vmSymbols.hpp:217），`permits` 子句列出的类名写进属性数组；
- 运行期：**子类加载时校验**——`InstanceKlass::has_as_permitted_subclass`（instanceKlass.cpp:282）检查 `_permitted_subclasses` 数组是否包含当前类；不在名单 → `ClassFormatError`；
- 检查点：`check_super_class`（:4005）阶段，父类是 sealed 时强制走校验。

## 六、public/protected/private：只有位没有兵

### 6.1 加载期只做互斥检查（classFileParser.cpp:4551-4559）

```cpp
static bool has_illegal_visibility(jint flags) {
  const bool is_public    = (flags & JVM_ACC_PUBLIC)    != 0;
  const bool is_protected = (flags & JVM_ACC_PROTECTED) != 0;
  const bool is_private   = (flags & JVM_ACC_PRIVATE)   != 0;
  return ((is_public && is_protected) ||
          (is_public && is_private) ||
          (is_protected && is_private));
}
```

**VM 对可见性只做一件事：三个位最多置一个**。访问控制（谁能调用）**不是 VM 的职责**：

1. javac 在编译期拒绝非法访问（private 方法跨类调用直接编译错误）；
2. 反射层（`Method.invoke`）按调用者做访问检查（`Reflection.verifyMemberAccess`）；
3. 反编译/字节码工具可以绕过——class 文件本身**不携带访问校验逻辑**。

> 与教科书印象相反：JVM 规范里访问标志是"文档性"的，**运行期强制靠 javac + 反射层**，VM 只防标志冲突（以及一些 special case 如 `invokespecial` 的私有方法调用验证）。

### 6.2 字段/方法级解析（:4621-4628）

```cpp
const bool is_public    = (flags & JVM_ACC_PUBLIC)      != 0;
const bool is_protected = (flags & JVM_ACC_PROTECTED)   != 0;
const bool is_private   = (flags & JVM_ACC_PRIVATE)     != 0;
const bool is_transient = (flags & JVM_ACC_TRANSIENT)   != 0;
const bool is_enum      = (flags & JVM_ACC_ENUM)        != 0;
```

字段/方法解析同一套位逻辑，存储进 `AccessFlags`（`accessFlags.hpp`）——之后 **is_public()/is_private() 就是查这个 2 字节的位**。

## 七、package/import：零字节码的双子

### 7.1 package：并入全限定名

`package` **没有字节码、没有属性、没有标志位**。它的全部贡献 = 类全限定名的前缀（`com.foo.Bar` 的 `com.foo`）。class 文件的 `this_class` 指向常量池里的**全限定名**（含包名），包名是名字的一部分。

运行期包概念：

- `Class.getPackage()` 从类名反推；
- 模块化后包归属模块——`ModuleEntry`（`moduleEntry.cpp:263`）与 `PackageEntry` 绑定，`same_module` 检查（`classFileParser.cpp:4328`）用于 sealed/访问校验；
- **包不是层级结构**：`java.util` 与 `java.util.concurrent` 是两个独立包，`import java.util.*` 不会导入子包。

### 7.2 import：全系列唯一的"完全零痕迹"

`import` 连全限定名都不写进 class 文件——javac 用它**解析简单名 → 全限定名**，解析完就丢弃。class 文件里**永远搜不到 import 的痕迹**（没有对应属性、常量池项、标志位）。

验证方法：编译带 10 个 import 的类，`javap -v` 逐字段搜——找不到任何 import 信息。对比 `record`/`sealed` 有专属属性——**import 是纯编译期消费者，连账本都不记**。

## 八、transient：标志活着，机制死了

### 8.1 VM 视角（accessFlags.hpp:57）

```cpp
bool is_transient() const { return (_flags & JVM_ACC_TRANSIENT) != 0; }
```

VM 里 transient 的全部存在 = **一个位 + 一个访问器**。搜索整个 HotSpot 只有三处：常量定义、解析读取、访问器——**没有任何机制消费它**。

### 8.2 谁在用这个位

1. **反射**：`Field.getModifiers()` 返回 TRANSIENT 位（`Modifier.isTransient`）；
2. **序列化**：`java.io.ObjectStreamClass`（Java 层）查标志，transient 字段跳过序列化；
3. **JSON 库等**：通过反射读标志决定是否序列化。

> 结论：**transient 的"机制"全在 Java 层（序列化框架），VM 只负责存位**。这与 strictfp（09 篇，JDK 17 连位都剥了）形成对照——transient 是"标志活着、机制在别处"。

## 九、module-info.class：解析路径与 ACC_MODULE

### 9.1 一个特殊的类（classFileParser.cpp:4492-4503）

```cpp
const bool is_module = (flags & JVM_ACC_MODULE) != 0;
assert(_major_version >= JAVA_9_VERSION || !is_module,
       "JVM_ACC_MODULE should not be set");
if (is_module) {
  Exceptions::fthrow(... NoClassDefFoundError(),
    "%s is not a class because access_flag ACC_MODULE is set", ...);
  return;
}
```

`module-info.class` 是 **ACC_MODULE（0x8000）特殊类**：**没有 super_class、没有字段、没有方法**（结构上不是类）。任何把它当类加载的尝试直接 NoClassDefFoundError。

### 9.2 解析路径：不在 HotSpot！

**关键发现**：整个 HotSpot 的 `classFileParser.cpp` 里**搜不到 Module 属性解析代码**——因为 **module-info.class 的 Module 属性由 Java 层解析**：

```
module-info.class 字节流
  → jdk.internal.module.ModuleDescriptor.read()   (java.base, Java 层)
  → 解析 Module 属性 → requires/exports/opens/uses/provides 表
  → jdk.internal.module.Modules.defineModule()
  → JVM_DefineModule()                            (jvm.cpp:1316, VM 入口)
  → ModuleEntry::create()                         (moduleEntry.cpp:263)
  → 绑定 ClassLoaderData / PackageEntry
```

- **Java 层**：`ModuleDescriptor`（`java.lang.module`）是模块描述符的"正主"，`ModuleInfo.java`（`jdk.internal.module`）负责从 class 字节流解析；
- **VM 层**：`JVM_DefineModule`（`jvm.cpp:1316`）接收 Java 层解析好的模块名/版本/requires 表，建 `ModuleEntry`（含 reads 表），之后 `can_read`（moduleEntry.cpp:125）/`add_read`（:158）做运行时模块读取检查；
- 为什么这么设计？**模块解析需要大量 Java 层便利设施（URI、版本比较、服务发现），放 VM 里不值得**——这是"Java 层做主、VM 收结果"的典型分工。

## 十、module 指令们：requires/exports/opens/uses/provides/with

### 10.1 它们不是 Java 关键字

JLS 里 `module` 是关键字，但 **`requires/exports/opens/uses/provides/with` 是"受限关键字"（restricted keywords）**——只在 `module-info.java` 上下文生效，脱离模块声明可以当标识符（比如变量名 `exports` 合法）。

### 10.2 在 Module 属性里的样子

`Module` 属性（u2 结构）包含五张表：

| 指令 | 属性表 | 内容 | VM 用途 |
|---|---|---|---|
| `requires` | Requires 表 | 模块名 + ACC_TRANSITIVE/STATIC_PHASE 标志 | `ModuleEntry::add_read` |
| `exports` | Exports 表 | 包名 + 目标模块列表（可选） | 包访问控制 |
| `opens` | Opens 表 | 包名 + 目标模块 | 反射开放控制 |
| `uses` | Uses 表 | 服务接口名 | 服务加载（`ServiceLoader`） |
| `provides ... with ...` | Provides 表 | 服务接口 + 实现类列表 | 服务发现 |

### 10.3 运行期谁消费

- **exports/opens**：模块化访问控制（`Module::isExported` / `isOpen`），非法访问 → `IllegalAccessError`；
- **uses/provides**：`ServiceLoader` 的服务发现（Java 层读 ModuleDescriptor，不查 META-INF/services）；
- **requires**：模块图的读取依赖——`ModuleEntry::can_read`（moduleEntry.cpp:125）决定模块间类可见性。

> 一句话：**module 系是"Java 层解析 + VM 存储 + Java 层消费"**——与 `import` 的"纯 javac 消费"是两个极端。

## 十一、JDK 28 vs 教科书差异

| 教科书说法 | JDK 28 真相 | 锚点 |
|---|---|---|
| 类标志里有 `ACC_SUPER` | 改名 **`JVM_ACC_IDENTITY`**（Valhalla），普通类自动带 identity 语义 | `jvm_constants.h:33` |
| `import` 会进 class 文件 | **零痕迹**——javac 解析完直接丢弃，javap 永远看不到 | — |
| `public/protected/private` 由 VM 强制 | VM **只做三互斥检查**；访问控制在 javac + 反射层 | `classFileParser.cpp:4551` |
| `transient` 是 VM 的序列化机制 | VM **只有位**（accessFlags.hpp:57），序列化跳过是 `ObjectStreamClass`（Java 层） | `accessFlags.hpp:57` |
| `module-info.class` 由 JVM 解析 | **Java 层解析**（`ModuleDescriptor`/`ModuleInfo`），HotSpot 收 `JVM_DefineModule` | `jvm.cpp:1316` |
| `requires/exports/...` 是关键字 | 是**受限关键字**，模块声明外可作标识符 | JLS §3.9 |
| 接口必须显式 abstract | 老版本自动补位（`is_interface && !is_abstract` 非法，JDK 6+） | `classFileParser.cpp:3151` |
| `sealed` 校验在编译期 | 编译期 + **加载期双重**：`has_as_permitted_subclass`（instanceKlass.cpp:282） | `instanceKlass.cpp:282` |
| 0x0020 是 ACC_SUPER（类） | 位复用：类上 IDENTITY、方法上 SYNCHRONIZED | `jvm_constants.h:33` |
| record 是纯 javac 语法 | `ACC_RECORD` + **Record 属性**（VM 存组件元数据供反射） | `classFileParser.cpp:3322` |

## 十二、验证实验

### 实验 1：标志位矩阵

```bash
# SealedDemo.java
public sealed class SealedDemo permits Sub {}
final class Sub extends SealedDemo {}
```

```bash
javap -v SealedDemo | grep -E "flags|PermittedSubclasses|sealed"
# 期望：flags: ACC_PUBLIC, ACC_SUPER(→ACC_IDENTITY), ACC_SEALED
#       PermittedSubclasses: 包含 Sub
```

### 实验 2：非法 permits 的加载期报错

```java
// BadSealed.java（编译会拒绝：not permitted）
public sealed class BadSealed permits NotListed {}
class NotListed extends BadSealed {}
```

```bash
javac BadSealed.java
# 期望：编译错误 "class is not allowed to extend sealed class"
# 用 javac --release 8 强制编译过 → 运行期 ClassFormatError（加载期校验证据）
```

### 实验 3：module-info 的 Java 层解析

```bash
javap -v module-info.class
# 期望：flags: ACC_MODULE；无 super_class/字段/方法
# Module 属性：requires/exports/opens 表
# 再用 -Xlog:module+load 观察 defineModule → JVM_DefineModule
java -Xlog:module+load=debug --module-path . -m m1/p.Main
```

### 实验 4：transient 只影响反射

```java
class T { transient int x; int y; }
Field f = T.class.getDeclaredField("x");
System.out.println(Modifier.isTransient(f.getModifiers())); // true
// ObjectStreamClass 跳过 x —— 但 VM 本身无任何 transient 机制
```

## 十三、系列收官：50 关键字的最终分布

从 01 全景的 7 域地图出发，02-10 共 9 篇深读完成，50 个关键字 + 3 个字面量的最终归宿：

| 系列 | 覆盖 | 机制类型 |
|---|---|---|
| 02 `synchronized` | 锁升级全链路 | 机制型（monitor 体系） |
| 03 `volatile` | JMM 屏障 | 机制型（MemBar） |
| 04 `new` | TLAB 分配 | 机制型（分配体系） |
| 05 `static` | 类初始化 | 机制型（clinit 状态机） |
| 06 `instanceof` | 子类型检查 | 机制型（Klass 双通道） |
| 07 `try/catch/finally/throw/throws` | 异常处理 | 机制型（异常表） |
| 08 `final` | 三副面孔 | 机制型 ×3 |
| 09 控制流+字面量+编译期型 | if/for/switch/return/yield + true/null/void/var/assert/strictfp/_ | 三派混合 |
| 10 声明域+访问控制+module | class/interface/enum/record/extends/implements/abstract/sealed/permits/public/protected/private/package/import/transient + module 系 | class 头部账本 |

**全系列结论**：

1. **机制型关键字**（有字节码/标志 → VM 机制）——读 `templateTable_x86.cpp` / `classFileParser.cpp` / `macroAssembler_x86.cpp`，行号锚点全部实证；
2. **编译期型关键字**（无字节码）——读 javac（`Gen.java`/`Lower.java`/`Resolve.java`），class 文件零痕迹；
3. **字面量与受限名**——`true/false/null` 是字面量，`var/yield/requires` 是受限名，教科书分类需要修正；
4. **JDK 28 特色**：无偏向锁、strict static、ACC_IDENTITY、Valhalla 渗透（值对象 `==`/`instanceof`）——三处都已在对应篇章下钻。

> 读到这里，50 个关键字已经**全部落位**——每个都能回答"它在 class 文件里长什么样、运行期由谁消费、行号在哪"。系列完结。
