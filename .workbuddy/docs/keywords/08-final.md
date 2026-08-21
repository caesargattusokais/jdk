# final：不可变的三副面孔

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Java 关键字源码跟读 · 第 08 篇（[回到系列索引](README.md)）
> 前置：[03 volatile JMM](03-volatile.md) · [05 static 类初始化](05-static.md) · [07 异常处理](07-exceptions.md)

---

## 快速概览

- **一句话结论**：`final` 不是"一个机制"，而是**三副面孔**，分别落到三个完全不同的落点：
  1. **final static 常量** → class 文件 **`ConstantValue` 属性**（只有 static final 才有！`classFileParser.cpp:1270`），VM 存进 `FieldInfo.initializer_index`，javac 做编译期常量折叠；
  2. **final 方法** → **不进 vtable**（`Object.java:471` 的 `wait0` 注释就是铁证），虚分派表里没有它的槽位，C2 可直接内联；
  3. **final 实例字段** → **JMM freeze 语义**：构造器出口插内存屏障（`Parse::do_exits`，`parse1.cpp:1069`），保证"构造器正常返回前，final 字段的写入对读线程可见"。
- **易混淆点**：`final` 和 `volatile` 的可见性保证不同——final 靠**构造器出口屏障**一次冻结（无需每次读写屏障），volatile 靠每次读写的屏障；`static final` 编译期常量**根本没有字段读取**（javac 直接内联字面量），运行期零成本。
- **JDK 28 新交互**：strict static fields（05 篇）校验时，**带 `ConstantValue` 的 strict static 字段自动豁免**（`classFileParser.cpp:6444`）——编译期常量必然有值，无需 clinit 里赋值。

---

## 目录

1. [final 的三副面孔：使用场景 → 机制映射](#一final-的三副面孔使用场景--机制映射)
2. [面孔 1：final static 常量 → ConstantValue 属性](#二面孔-1final-static-常量--constantvalue-属性)
3. [面孔 2：final 方法不进 vtable](#三面孔-2final-方法不进-vtable)
4. [面孔 3：final 实例字段的 JMM freeze](#四面孔-3final-实例字段的-jmm-freeze)
5. [javac 视角：编译期常量折叠](#五javac-视角编译期常量折叠)
6. [strict static 与 ConstantValue 的交互](#六strict-static-与-constantvalue-的交互)
7. [JDK 28 vs 教科书差异](#七jdk-28-vs-教科书差异)
8. [验证实验](#八验证实验)
9. [与系列主线闭环](#九与系列主线闭环)

---

## 一、final 的三副面孔：使用场景 → 机制映射

| 使用场景 | 编译期产物 | 运行期机制 | 核心锚点 |
|---|---|---|---|
| `static final int X = 42` | `ConstantValue` 属性 + 内联字面量 | 无字段读取（常量折叠） | `classFileParser.cpp:1270` |
| `final void m()` | 无 vtable 槽位（ACC_FINAL） | 虚分派跳过 / 直接内联 | `Object.java:471` |
| `final int f = ...`（实例字段） | `ACC_FINAL` 标志 | 构造器出口屏障（freeze） | `parse1.cpp:1069-1114` |
| `final class C` | `ACC_FINAL`（类级） | 链接期禁止子类化（Verifier） | classFileParser flags |
| `final` 参数/局部变量 | **无任何痕迹** | 无 | javac 纯语法 |

> 关键认知：`final` 用在**类/方法/字段**上机制完全不同，用在**参数/局部变量**上则是**零开销的纯编译期约束**（javac 检查不重新赋值，class 文件无痕迹）。判断 final 属于哪张面孔：看它修饰的是什么。

## 二、面孔 1：final static 常量 → ConstantValue 属性

### 2.1 属性解析（classFileParser.cpp:1270）

字段属性循环里，`ConstantValue` 被解析：

```cpp
if (is_static && attribute_name == vmSymbols::tag_constant_value()) {
  // ignore if non-static                    ← 非 static 直接忽略！
  if (constantvalue_index != 0) {
    classfile_parse_error("Duplicate ConstantValue attribute in class file %s", THREAD);  // :1273
  }
  guarantee_property(attribute_length == 2,                        // :1277 长度固定 2 字节
                     "Invalid ConstantValue field attribute length %u ...", ...);
  constantvalue_index = cfs->get_u2(CHECK);                        // :1281 读常量池索引
  if (_need_verify) {
    verify_constantvalue(cp, constantvalue_index, signature_index, CHECK);  // :1283
  }
}
```

要点：
- **只处理 `is_static`**：`final int f = 1`（实例字段）**没有** ConstantValue 属性——实例字段的初始值在构造器里赋值，不属于字段属性；
- **长度固定为 2**（一个 u2 常量池索引），`verify_constantvalue`（错误信息在 `classFileParser.cpp:880`："Bad initial value index"）校验索引指向的类型与字段签名匹配（int 字段只能指向 CONSTANT_Integer 等）；
- 解析结果存进 **`FieldInfo.initializer_index`**——VM 侧字段的"初始值"索引（`classFileParser.cpp:6443` 用它做 strict static 判断）。

### 2.2 为什么 javac 对 final static 做常量折叠

```java
static final int MAX = 100;
int x = MAX + 1;   // 编译成 bipush 101，不读字段！
```

javac 的常量折叠规则（JLS §15.29 常量表达式）：**final static + 基本类型/String + 常量表达式** → 使用处直接内联字面量。后果：
- **运行期没有 getstatic**：`MAX` 的读取零成本（字节码里直接是 `bipush 101`）；
- **`Class.MAX` 变成编译期绑定**：改 `MAX` 值需要重编译使用方（经典"改常量不生效"坑的根源）；
- **反射仍能读到旧值**：字段对象（`MAX` 的 Field）在 class 文件里保留，运行期 get 走 ConstantValue。

## 三、面孔 2：final 方法不进 vtable

`Object.java:471-472` 是最直接的证据：

```java
// final modifier so method not in vtable
private final native void wait0(long timeoutMillis) throws InterruptedException;
```

- **vtable 是什么**：Klass 里的虚方法分派表（`klassVtable`，见 06 篇 `start_of_vtable`）。每次 `invokevirtual` 按接收者实际类型查表跳转。
- **final 方法的待遇**：不占 vtable 槽位（`ACC_FINAL` 方法在链接期被排除出 vtable），调用方可以用 `invokespecial`/直接调用，**C2 拿到确切目标直接内联**——`wait0` 是 native 且 private final，绑定毫无歧义；
- **Object 源码注释的用意**：`wait0` 若进 vtable，虚拟线程/子类可能劫持或覆盖分派路径——`final` 在这里是**性能 + 安全**双保证；
- 普通 final 方法同理：`public final void f()` 编译后调用点是 `invokevirtual`（语法上），但**链接期解析时目标唯一**，C2 无条件内联（除非太大）。

> 对比：final 类（`final class`）是把"整个类的所有方法都不许覆盖"——链接期 Verifier 拒绝子类化，属于声明域语义，比 final 方法更彻底。

## 四、面孔 3：final 实例字段的 JMM freeze

### 4.1 问题：final 字段为什么需要屏障？

JMM 保证：**构造器正常返回后，其他线程看到引用时，final 字段已初始化**（即使没有同步）。实现方式是"冻结"——构造器出口放一道屏障，把构造器内对 final 字段的写入"卡"在发布之前。

### 4.2 C2 实现：Parse::do_exits（parse1.cpp:1069）

```cpp
// Figure out if we need to emit the trailing barrier. The barrier is only
// needed in the constructors, and only in three cases:
// 1. The constructor wrote a final or a @Stable field. All these
//    initializations must be ordered before any code after the constructor
//    publishes the reference to the newly constructed object.
// 2. Experimental VM option (AlwaysSafeConstructors) ...
// 3. On processors which are not CPU_MULTI_COPY_ATOMIC (e.g. PPC64) ...
if (method()->is_object_constructor() &&
     (wrote_non_strict_final() || wrote_stable() ||
       (AlwaysSafeConstructors && wrote_fields()) ||
       (support_IRIW_for_not_multiple_copy_atomic_cpu && wrote_volatile()))) {
  Node* recorded_alloc = alloc_with_final_or_stable();
  _exits.insert_mem_bar(UseStoreStoreForCtor ? Op_MemBarStoreStore : Op_MemBarRelease,
                        recorded_alloc);                     // :1113
  ...
}
```

三个要点：

| 要点 | 细节 | 锚点 |
|---|---|---|
| **触发条件** | 构造器里写了 final 或 @Stable 字段（`wrote_non_strict_final()`） | parse1.cpp:1108-1111 |
| **屏障类型** | `UseStoreStoreForCtor`（JDK 9+ 默认）→ `Op_MemBarStoreStore`；否则 `Op_MemBarRelease` | parse1.cpp:1113 |
| **x86 落地** | StoreStore/Release 在 x86 上**空编码**（03 篇已证）——x86 TSO 天然有序，屏障是"零成本语义" | 03-volatile §7 |

- `wrote_non_strict_final` 标志在解析开始时清空（parse1.cpp:455 `_wrote_non_strict_final = false`），构造器每写一个 final 字段置位；
- **异常路径不插屏障**（注释 1103-1106："exceptional returns cannot publish normally"）——构造器抛异常时对象不会发布，无需冻结；
- 与逃逸分析交互（1119-1122）：若分配对象不逃逸，`compute_MemBar_redundancy` 可把冗余屏障消掉。

### 4.3 解释器路径的 freeze

解释器执行构造器没有显式屏障（依赖解释器逐条执行天然顺序 + x86 TSO）。C2 的屏障是 JIT 层面的加强——**语义由 JMM 保证，实现按编译路径分层**：C2 显式插屏障，解释器靠 TSO。

## 五、javac 视角：编译期常量折叠

（读 javac 的入口提示：`com.sun.tools.javac.comp.ConstFold` / `Attr`，JDK 28 路径 `src/jdk.compiler/share/classes/com/sun/tools/javac/comp/`）

javac 对 `final static` 常量表达式（JLS §15.29）的处理链：

1. **识别**：字段声明 `static final` + 初始化器是常量表达式（字面量、算术、其他常量）；
2. **折叠**：使用处（`Attr`/`ConstFold`）把 `MAX` 替换为常量值——`javap` 看不到 `getstatic MAX`；
3. **保留属性**：字段仍写 `ConstantValue` 属性（供反射、序列化、其他编译器）；
4. **String 常量**：`static final String S = "x"` 内联字符串字面量（进字符串常量池，运行期 `ldc`）。

> 反例：`static final int X = rand()`——不是常量表达式，javac 不折叠，X 留在 clinit 里赋值（05 篇），使用处是真正的 `getstatic`。

## 六、strict static 与 ConstantValue 的交互

JDK 28 的 strict static fields（05 篇：clinit 结束后逐位检查 strict static 是否被赋值）与 ConstantValue 有专门交互：

```cpp
// classFileParser.cpp:6444
if (fi.initializer_index() != 0) {
  // skip strict static fields with ConstantValue attributes
} else {
  _fields_status->adr_at(fi.index())->update_strict_static_unset(true);
  ...
}
```

逻辑：**带 ConstantValue 的 strict static 字段在 clinit 前就"有值"了**（编译期常量），不需要在 clinit 里赋值——所以不标记为 unset，校验直接豁免；其余 strict static 字段标记 unset，clinit 结束逐位检查（`instanceKlass.cpp:1587`）。

> 这也解释了 05 篇实验里的现象：`static strict final int K = 1;` 不会触发 strict 校验异常，而 `static strict int x;`（无初始化）会在 clinit 后报错。

## 七、JDK 28 vs 教科书差异

| 教科书说法 | JDK 28 真相 | 证据 |
|---|---|---|
| final 字段"值不可变" | 是 **JMM freeze**：构造器出口屏障保证发布前可见 | `parse1.cpp:1069-1114` |
| final 实例字段也有 ConstantValue | **只有 static final 有**，实例 final 在构造器里赋值 | `classFileParser.cpp:1270`（`is_static &&`） |
| final 保证"高效"（笼统） | 三种面孔三种效率：常量零成本 / 方法可内联 / 字段一次屏障 | §1 映射表 |
| final 字段需要每次访问同步 | **不需要**：一次性 freeze，之后无限读（与 volatile 每次屏障对比） | `parse1.cpp:1113` |
| x86 上 final 有运行时开销 | **零开销**：MemBarStoreStore/Release 在 x86 空编码 | 03-volatile §7 |
| final 局部变量"优化" | 纯编译期约束，class 文件**无痕迹** | §1 末行 |
| 改 final static 常量要重编译使用方 | 是（javac 内联字面量），与运行期无关 | §2.2 |

## 八、验证实验

```java
// FinalDemo.java
public class FinalDemo {
    static final int MAX = 100;              // 常量表达式 → ConstantValue
    static final int RND = (int)(Math.random()*10);  // 非常量 → clinit
    final int id;                            // 实例 final
    FinalDemo() { id = 42; }
    final void f() {}
    public static void main(String[] a) {
        FinalDemo d = new FinalDemo();
        System.out.println(MAX + RND + d.id);
        d.f();
    }
}
```

1. **看 ConstantValue**：`javap -v FinalDemo` → `MAX` 字段有 `ConstantValue: int 100`；`RND` 没有（进 `<clinit>`）；`id` 没有（实例字段）；
2. **看常量折叠**：`javap -c` → main 里 `MAX` 的使用处是 `bipush 100` 而非 `getstatic`；`RND` 是 `getstatic`；
3. **看 vtable**：`javap -v` 里 `f()` 有 `ACC_FINAL`；对照 `Object.java:471` 的 wait0 注释；
4. **看 freeze 屏障**：`java -XX:+PrintOpto -XX:CompileCommand=compileonly,FinalDemo::'<init>' FinalDemo` → 输出 "writes finals/@Stable and needs a memory barrier"（parse1.cpp:1125）；
5. **strict 交互**：JDK 28 下编译 `static strict final int K = 1;`（若 `-XX:+StrictStaticFields` 生效）不报错，而 `static strict int x;` 会抛 strict 异常——验证 §6。

## 九、与系列主线闭环

- **static（05）**：非常量 `final static` 在 `<clinit>` 赋值，走 05 的状态机；`ConstantValue` 常量则**绕过 clinit**（05 篇"主动使用"的例外场景）；
- **volatile（03）**：final freeze = 一次 `MemBarStoreStore/Release`（构造器出口），volatile = 每次访问插屏障——两者互补：final 管"发布前"，volatile 管"发布后"；
- **new（04）**：final 字段冻结的正是 04 篇 TLAB 里分配的对象——屏障插在构造器出口，对象还没被外部引用；
- **instanceof（06）**：final 方法不占 vtable 槽，`invokevirtual` 的分派表因此更小——vtable 布局（`klassVtable`）与 06 篇的 `super_check_offset` 是同一块 Klass 头部数据；
- **下一站（09）**：控制流与字面量补完篇——if/else/switch/for/while/do/break/continue/return + true/false/null/void/var 等剩余关键字的字节码全景。

---

> 下一篇：[09 控制流与字面量补完](09-control-flow.md) —— 剩余关键字的字节码全景
