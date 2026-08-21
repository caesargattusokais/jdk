# Java 关键字源码跟读系列

> 版本：JDK 28 主线（`D:\project\jdk`）
> 定位：Object 读完之后的主线——**关键字是语言骨架，每个关键字背后要么是 HotSpot 机制，要么是 javac 语义**

## 为什么读关键字

Object 是"类"的根，但**关键字才是语言的骨架**。`synchronized` 背后是整个 monitor 体系，`volatile` 背后是 JMM 内存屏障，`new` 背后是 TLAB 分配，`instanceof` 背后是 Klass 子类型比较——每个关键字都是一条通向 HotSpot 的线索。本系列把它们逐个拉出来下钻。

## 目录

| 编号 | 主题 | 核心内容 | 配套动画 | 状态 |
|---|---|---|---|---|
| [01](01-keywords-overview.md) | 关键字全景 | 50 关键字按机制分 7 域（SVG 地图）+ 关键字→HotSpot 机制映射表（真实行号锚点）+ 三类本质区别 + 深读优先级 | — | ✅ |
| [02](02-synchronized-lockupgrade.md) | `synchronized` | 锁升级全链路：字节码 → 解释器模板 → fast_lock 内联 CAS（LockStack 记账）→ 四段式 enter → 膨胀（hash 先行）→ ObjectMonitor 排队 → 释放唤醒；JDK 28 无偏向锁真相 | [🎬 锁升级动画](02-synchronized-lockupgrade-animation.html)（12 步） | ✅ |
| [03](03-volatile.md) | `volatile` | 字节码无痕（ACC_VOLATILE）→ C2 插 MemBar（写前 Release / 写后 Volatile / 读后 Acquire）→ x86 真相（Acquire/Release 空编码，仅 volatile 写有 `lock addl`）→ DCL 构造器屏障收尾 | [🎬 屏障动画](03-volatile-membar-animation.html)（12 步） | ✅ |
| [04](04-new.md) | `new` | 字节码 0xbb → 解释器四连查 → **TLAB bump-pointer**（3 条指令零锁）→ 慢路径三段式（fast / refill / 堆外）→ 对象头初始化（mark=prototype）→ 构造器 → C2 标量替换消灭分配 | [🎬 TLAB 动画](04-new-tlab-animation.html)（12 步） | ✅ |
| [05](05-static.md) | `static` | `ACC_STATIC` + 合成 `<clinit>` → 六态状态机（allocated→…→fully_initialized/error）→ `initialize_impl` 十一小步（mirror 初始化锁 / 递归重入 / 父类先行 / strict static 校验）→ `clinit_barrier` 两跳快路径 | [🎬 clinit 动画](05-static-clinit-animation.html)（12 步） | ✅ |
| [06](06-instanceof.md) | `instanceof` | 字节码 0xc1 → 模板五段（atos→itos 出 0/1）→ `check_klass_subtype` 快路径三段（self-check / 显示表 O(1) / `search_secondary_supers` 慢路径）→ 接口位图+哈希+探测 → C2 `gen_instanceof` 三路 merge → 与 `checkcast` 对比（抛异常 vs 换类型） | [🎬 类型检查动画](06-instanceof-animation.html)（12 步） | ✅ |
| [07](07-exceptions.md) | `try/catch/finally/throw/throws` | javac 摊平异常表（`ExceptionTableElement` 4×u2）→ `fast_exception_handler_bci_for` 三步查找（区间覆盖 → catch-all 短路 → `is_subtype_of` 复用 instanceof 算法）→ `athrow` null_check 转 NPE → 无 handler 解栈上抛 → finally 复制语义 → `throws` 仅 `Exceptions` 属性 | [🎬 异常处理动画](07-exceptions-animation.html)（12 步） | ✅ |
| [08](08-final.md) | `final` | 三副面孔：① static final → `ConstantValue` 属性 + javac 常量折叠（JDK 28 strict static 自动豁免）② final 方法 → 不进 vtable + C2 直接内联 ③ final 实例字段 → JMM freeze（`Parse::do_exits` 构造器出口 MemBar，x86 空编码） | [🎬 三面孔动画](08-final-animation.html)（12 步） | ✅ |
| [09](09-control-flow-and-literals.md) | 控制流+字面量+编译期型 | `if/else`（0x99-0xa6 共享模板）· 循环/break/continue = `goto`（回边计数→OSR）· `switch` 双形态（javac 成本公式 + lookupswitch 改写为线性/二分，阈值 5）· `return` 六合一模板（poll+narrow+remove_activation）· `yield`（受限标识符）· `true/false/null`（iconst/aconst_null）· `void/var/_` · `assert`（$assertionsDisabled 降级）· `strictfp`（ACC_STRICT 剥除） | [🎬 控制流动画](09-control-flow-and-literals-animation.html)（12 步） | ✅ |
| [10](10-declaration-and-module.md) | 声明域+访问控制+module（收官） | `class/interface/enum/record/abstract/sealed/permits/extends/implements` → access_flags 一本账（三组掩码 + 位复用 + ACC_IDENTITY）· `public/protected/private` 只有位没有兵 · `package/import` 零字节码 · `transient` 标志活着机制死了 · `module-info.class` **Java 层解析**（`ModuleDescriptor`→`JVM_DefineModule`）+ requires/exports/opens/uses/provides/with 五张表 | [🎬 声明域动画](10-declaration-and-module-animation.html)（12 步） | ✅ |

> 深读顺序见 [01 第五节](01-keywords-overview.md#五深读优先级建议)：synchronized → volatile → new → static → instanceof → try/catch → final。

## 阅读方法备忘（关键字版）

1. **先判断类别**：机制型 / 编译期型 / 语义型（判断方法：class 文件里搜不搜得到痕迹）。机制型读 HotSpot，编译期型读 javac，语义型读 JLS。
2. **字节码是第一落点**：多数机制型关键字有专属字节码（`monitorenter`、`athrow`、`tableswitch`），从 `bytecodes.hpp` 定义出发找实现。
3. **模板解释器看 cpu 目录**：`src/hotspot/cpu/x86/templateTable_x86.cpp`（注意不在 share 目录）。
4. **标志位看 classFileParser**：`ACC_VOLATILE`、`ACC_PRIVATE` 等访问标志统一在 `classFileParser.cpp` 解析。
5. **用自己编的 JDK 28 做实验**：`-Xlog:jni+resolve=debug` 验证绑定、`-XX:+UseTLAB` 开关验证分配路径。

## 待跟进主题

- [x] `synchronized` 锁升级全链路（02 完成；衔接 Object 06 的 `inflate_locked_or_imse`）
- [x] `volatile` 的 C2 MemBar 插入规则（03 完成：写前 Release / 写后 Volatile / 读后 Acquire；x86 仅 StoreLoad 需真指令）
- [x] `new` 的 TLAB 慢路径与 GC 交互（04 完成：fast / refill / 堆外三段式 + ResizeTLAB + 标量替换）
- [x] `static` 的 `<clinit>` 状态机（05 完成：六态 + mirror 锁 + 递归重入 + strict static 校验；类初始化死锁已通过 `_init_thread` 递归检测规避，见 05 §7）
- [x] `instanceof` 与 `checkcast` 的差异（06 完成：前者消耗栈顶出 0/1、后者失败抛异常且对象原样保留）
- [x] 异常表查找算法（07 完成：`fast_exception_handler_bci_for` 三步：区间覆盖 → catch-all 短路 → `is_subtype_of`；复用 06 的 instanceof 算法）
- [x] `final` 字段在 JMM 的语义（08 完成：构造器出口 freeze 屏障；x86 空编码，JDK 28 strict static 对 ConstantValue 豁免）
- [x] module 系关键字的 `module-info.class` 解析（10 完成：**不在 HotSpot**——classFileParser 无 Module 属性解析代码，全由 java.base Java 层 `ModuleDescriptor` 解析后走 `JVM_DefineModule` jvm.cpp:1316 建 ModuleEntry）
