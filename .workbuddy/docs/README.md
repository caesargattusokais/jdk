# JDK 源码跟读记录

> 基于 `D:\project\jdk`（JDK 28 主线）的源码阅读笔记。
> 所有行号均指向本仓库源码，以 `文件:行号` 标注，可直接在 IDEA 中跳转核对。
> 约定：`share` 表示跨平台共享源码（`src/hotspot/share`、`src/java.base/share`）。

## 目录

| 主题系列 | 说明 | 状态 |
|---|---|---|
| [Object 源码跟读系列](object/README.md) | 13 个方法全景 + getClass/hashCode/clone/equals/toString/wait/notify/finalize 逐个跟读 | ✅ 7 篇完成 |
| [Java 关键字源码跟读系列](keywords/README.md) | 50 关键字按机制分 7 域全景 + 9 条深读主线：synchronized / volatile / new / static / instanceof / 异常 / final / 控制流+字面量 / 声明域+module | ✅ 10 篇收官 |
| [常量池源码跟读系列](constantpool/README.md) | 类文件常量池 #12 结构解析 + 运行时常量池与解析（懒解析 / 缓存 / 双胞胎） | ✅ 2 篇完成 |
| [类加载源码跟读系列](classload/README.md) | 加载与双亲委派 + 链接三阶段（verify/link/prepare-resolve）+ 初始化与卸载 | ✅ 3 篇收官 |

## Object 系列速览

| 编号 | 主题 | 核心链路 |
|---|---|---|
| [01](object/01-object-overview.md) | Object 总览 | 方法全景 + native 绑定机制演进（registerNatives 的消失） |
| [02](object/02-getClass.md) | `getClass()` | JNI 名字解析 → `jni_GetObjectClass` → Java mirror |
| [03](object/03-hashCode.md) | `hashCode()` | VM 注册 → `JVM_IHashCode` → `FastHashCode` → mark word CAS |
| [04](object/04-clone.md) | `clone()` | `JVM_Clone`：Cloneable 检查 → 分配 → 浅拷贝 → finalizer |
| [05](object/05-equals-toString.md) | `equals()` / `toString()` | 纯 Java：引用相等 / `类名@hash` |
| [06](object/06-wait-notify.md) | `wait()` / `notify()` / `notifyAll()` | `wait0` → 锁膨胀 → `ObjectMonitor` |
| [07](object/07-finalize.md) | `finalize()` | 空方法 + JEP 421 废弃史 + `--finalization=` 开关 |

## 关键字系列速览

| 编号 | 主题 | 核心链路 |
|---|---|---|
| [01](keywords/01-keywords-overview.md) | 关键字全景 | 50 关键字 7 域分类地图（SVG）+ 关键字→HotSpot 机制映射表 + 深读优先级 |
| [02](keywords/02-synchronized-lockupgrade.md) | `synchronized` | 字节码 → 解释器模板 → fast_lock 内联 CAS（LockStack 记账）→ 四段式 enter → 膨胀（hash 先行）→ ObjectMonitor 排队 → 释放唤醒；JDK 28 无偏向锁真相（SVG 状态机） |
| [03](keywords/03-volatile.md) | `volatile` | 字节码无痕（ACC_VOLATILE）→ C2 插 MemBar（写前 Release / 写后 Volatile / 读后 Acquire）→ x86 真相：Acquire/Release 空编码、仅 volatile 写有 `lock addl`（SVG 屏障时序）→ DCL 构造器屏障收尾 |
| [04](keywords/04-new.md) | `new` | 字节码 0xbb → 解释器四连查（含 clinit 屏障）→ TLAB bump-pointer（3 条指令零锁）→ 慢路径三段式（fast / refill / 堆外）→ 对象头初始化（mark=prototype）→ 构造器 → C2 标量替换消灭分配（SVG 分配流程图） |
| [05](keywords/05-static.md) | `static` | `ACC_STATIC` + 合成 `<clinit>` → 六态状态机 → `initialize_impl` 十一小步（mirror 初始化锁 / `_init_thread` 递归重入 / 父类先行 / strict static 校验）→ `clinit_barrier` 两跳快路径（SVG 状态机） |
| [06](keywords/06-instanceof.md) | `instanceof` | 字节码 0xc1 → 模板五段（atos→itos）→ `check_klass_subtype` 快路径三段（self-check / 显示表 / 慢路径）→ 接口位图+哈希+探测 → C2 `gen_instanceof` 三路 merge（SVG 链路图） |
| [07](keywords/07-exceptions.md) | `try/catch/finally/throw/throws` | 异常表 4×u2 结构 → `fast_exception_handler_bci_for` 三步查找（区间 / catch-all / 子类型复用 06 算法）→ `athrow` 的 null 转 NPE → finally 复制语义（SVG 四段图） |
| [08](keywords/08-final.md) | `final` | 三副面孔：static final → `ConstantValue` 属性 + 常量折叠（strict 豁免）；final 方法 → 不进 vtable；final 字段 → 构造器出口 freeze 屏障（SVG 三面孔卡片） |
| [09](keywords/09-control-flow-and-literals.md) | `if/else`·循环·`switch`·`return`·`yield`·字面量·`var`·`assert`·`strictfp` | if 家族 0x99-0xa6 共享 4 个模板（条件参数化）→ 循环/break/continue = `goto`（回边计数→OSR）→ switch 双形态（javac 成本公式 + lookupswitch 改写阈值 5）→ return 六合一（poll+narrow+remove_activation）→ assert 降级 `$assertionsDisabled`+athrow → strictfp ACC_STRICT 剥除 |
| [10](keywords/10-declaration-and-module.md) | 声明域+访问控制+module（收官） | `class/interface/enum/record`·`sealed/permits`·`extends/implements` → access_flags 三组掩码+位复用+ACC_IDENTITY → 访问控制"只有位没有兵" → `package/import` 零字节码 · `transient` 只有位 → **module-info.class 由 java.base Java 层解析**（ModuleDescriptor→JVM_DefineModule）→ 50 关键字最终分布 |

## 常量池系列速览

| 编号 | 主题 | 核心链路 |
|---|---|---|
| [01](constantpool/01-classfile-cp.md) | 类文件常量池 `#12` 长什么样 | `cp_info` 双字节表结构 → 14 种 tag（utf8/class/nameandtype 等）→ javac 顺序号与常量池索引的关系 → `Dog` 示例逐项拆解 → `ClassFileParser::parse_constant_pool` 实读 |
| [02](constantpool/02-runtime-cp.md) | 运行时常量池与解析 | `ConstantPool` 驻留堆内 → 符号引用 vs 直接引用 → 懒解析（`klass_at_impl` / `resolve_invoke`）→ 解析缓存与 `ConstantPoolCache` → 双胞胎现象（Class 镜像 vs CP 项） |

## 类加载系列速览

| 编号 | 主题 | 核心链路 |
|---|---|---|
| [01](classload/01-load-parent-delegation.md) | 加载与双亲委派 | `ClassLoader.loadClass` :501/:546 → 加锁+`findLoadedClass` :549/:551 → 向上委派 :556/:558 → `defineClass` native → `JVM_DefineClass` → `SystemDictionary::resolve_instance_class_or_null` :606 协调 → `PlaceholderTable` 占位防循环 :225/:255 → `ClassLoader::load_class` :1100 → `KlassFactory` :172 → `create_instance_klass` :5304 |
| [02](classload/02-link-verify.md) | 链接三阶段 | `parse_stream` :6024（魔数/版本/常量池）→ `Verifier::verify` :183 三道检查 → `link_class_impl` :1123（父类递归 :1150 / rewrite :1232 / link_methods :1238 / vtable+itable :1256）→ 准备静态字段 :522 → 懒解析不集中解析（`klass_at_impl` :631 / `resolve_invoke` :1715） |
| [03](classload/03-init-unload.md) | 初始化与卸载（收官） | 主动使用触发（`_new` :223 / 静态字段 :741 / 常量不触发）→ `InstanceKlass::initialize` :961 → `initialize_impl` :1417（init_lock 互斥 :1436 / 等待 :1442 / 递归放行 :1454 / 置 being_initialized :1498）→ 父类先行 :1539 → `call_class_initializer` :2019 执行 `<clinit>` → 成功 `fully_initialized` :1620 / 失败错误表 :1341 + `ExceptionInInitializerError` :1645 → 卸载 `do_unloading` :410 按加载器整批回收 |

## 交互动画

| 动画 | 配套文档 | 说明 |
|---|---|---|
| [hashCode 身份哈希 · mark word 流程](object/03-hashCode-markword-animation.html) | [Object 03](object/03-hashCode.md) | 8 步逐步播放：调用 → JNI → 读对象头 → 检查 hash → xor-shift 生成 → CAS 安装 → 再次调用命中。Space 播放/暂停，← → 步进，R 重置，离线可打开 |
| [synchronized 锁升级全链路](keywords/02-synchronized-lockupgrade-animation.html) | [关键字 02](keywords/02-synchronized-lockupgrade.md) | 12 步逐步播放：T1 无锁→轻量锁（CAS + LockStack）→T2 自旋→膨胀（hash 先行）→ObjectMonitor 排队→释放唤醒，mark word 锁位 + 线程泳道 + LockStack/ObjectMonitor 实时视图 |
| [volatile 内存屏障](keywords/03-volatile-membar-animation.html) | [关键字 03](keywords/03-volatile.md) | 12 步逐步播放：无 volatile 对照（StoreLoad 重排丢消息）→ 加 volatile → C2 插屏障（写前 Release / 写后 Volatile / 读后 Acquire）→ `lock addl` 排空 Store Buffer → happens-before 建立 → x86 成本对比 |
| [new / TLAB 对象诞生](keywords/04-new-tlab-animation.html) | [关键字 04](keywords/04-new.md) | 12 步逐步播放：字节码 0xbb → 四连查 → TLAB bump-pointer 指针前移 → 空间不足进慢路径（剩余空间决策）→ refill / 大对象堆外 → 对象头初始化 → 构造器 → C2 标量替换把 new 整个删除 |
| [static / 类初始化 &lt;clinit&gt;](keywords/05-static-clinit-animation.html) | [关键字 05](keywords/05-static.md) | 12 步逐步播放：T1 首触 clinit_barrier → 抢 mirror 初始化锁 → being_initialized → 执行 &lt;clinit&gt;（strict 位逐字段清零）→ T2 并发触达挂起等待 → notify_all 唤醒 → T2 放行；含递归重入彩蛋与错误路径回顾 |
| [instanceof / 类型检查全链路](keywords/06-instanceof-animation.html) | [关键字 06](keywords/06-instanceof.md) | 12 步逐步播放：null 短路 → quicken → 取 Klass → self-check / 显示表 O(1) / 位图+哈希三场景 → 结果 merge → checkcast 对比 |
| [异常处理 / 异常表查表](keywords/07-exceptions-animation.html) | [关键字 07](keywords/07-exceptions.md) | 12 步逐步播放：FNFE 抛出 → 解栈 → 异常表扫描（区间覆盖 → is_subtype_of 命中 → handler）→ finally 复制 → catch-all / 无 handler 分支 |
| [final / 三副面孔](keywords/08-final-animation.html) | [关键字 08](keywords/08-final.md) | 12 步逐步播放：面孔①常量折叠 + ConstantValue 解析 → 面孔②vtable 无槽 → 面孔③do_exits 屏障（x86 空编码）→ strict 交互 → final vs volatile → 系列闭环 |
| [控制流 / switch 双形态与 return 六合一](keywords/09-control-flow-and-literals-animation.html) | [关键字 09](keywords/09-control-flow-and-literals.md) | 12 步逐步播放：三派分类 → if/else 编译 → 共享模板 → 循环=if+goto → 回边计数+OSR → javac 成本公式 → tableswitch O(1) → lookupswitch 改写（阈值 5）→ return 家族 → _return 三步 → 字面量型 → 纯编译期型 → 系列闭环 |
| [声明域 / access_flags 与 module Java 层解析](keywords/10-declaration-and-module-animation.html) | [关键字 10](keywords/10-declaration-and-module.md) | 12 步逐步播放：access_flags 三组掩码 → 位复用陷阱 → 四种形态组合 → record → sealed 双重校验 → extends/implements 链接期继承链 → 访问控制"只有位" → package/import 零痕迹 → transient 只有位 → module-info.class Java 层解析 → requires/exports/opens/uses/provides 五表 → 系列收官 |
| [类文件常量池 / #12 长什么样](constantpool/01-classfile-cp-animation.html) | [常量池 01](constantpool/01-classfile-cp.md) | 15 步逐步播放：`Dog` 字节码 → `cp_info` 双字节表 → tag 速查 → utf8/class/nameandtype/ref 逐项拆解 → 索引→符号引用 → javac 顺序号规律 → `parse_constant_pool` 实读 |
| [运行时常量池 / 懒解析与缓存](constantpool/02-runtime-cp-animation.html) | [常量池 02](constantpool/02-runtime-cp.md) | 15 步逐步播放：类文件 CP → 运行时常量池 → 符号 vs 直接引用 → 懒解析（首次用才解）→ `klass_at_impl` / `resolve_invoke` → 解析缓存 `ConstantPoolCache` → 双胞胎 → 一次解析永续复用 |
| [加载与双亲委派](classload/01-load-parent-delegation-animation.html) | [类加载 01](classload/01-load-parent-delegation.md) | 15 步逐步播放：`loadClass` :501 入口 → 加锁+已加载查表 :549/:551 → 向上委派 :556 → `defineClass` → native 边界 `JVM_DefineClass` → `SystemDictionary` 协调 :606 → `PlaceholderTable` 占位防循环 → `ClassLoader::load_class` :1100 → `KlassFactory` :172 → 循环检测 → 全链路闭环 |
| [链接三阶段 / verify·link·prepare](classload/02-link-verify-animation.html) | [类加载 02](classload/02-link-verify.md) | 15 步逐步播放：`parse_stream` 魔数/版本/常量池 → `Verifier::verify` 三道检查 → 失败 VerifyError → 先父后己 → `rewrite_class` → `link_methods` → vtable/itable 接线 → `set_init_state(linked)` → prepare 分配静态字段 → 懒解析动机 → 闭环 |
| [初始化与卸载 / &lt;clinit&gt; 的一生](classload/03-init-unload-animation.html) | [类加载 03](classload/03-init-unload.md) | 15 步逐步播放：主动使用触发（`_new` :223 / 静态字段 :741 / 常量不触发）→ 状态机（init_lock :1436 / 等待 :1442 / 递归放行 / error 态）→ 父类先行 :1539 → `call_class_initializer` :2019 念誓词 → 成功 `fully_initialized` :1620 / 失败错误表 :1341 → 卸载 `do_unloading` :410 整批回收 → 三站收官 |

> 动画为自包含 HTML（无外部依赖），浏览器双击即可播放；每步代码面板引用真实源码行号，可直接回 IDEA 跳转核对。

## 阅读方法备忘

1. **入口从 Java 层找**：`src/java.base/share/classes/java/lang/` 下定位类 → 找到 `native` 方法。
2. **绑定机制先分清**：JDK 28 里大部分核心 native 由 VM 静态注册（`javaClasses.cpp` 的 `register_natives` 表），少量走 JNI 名字解析（`libjava/*.c`）。用 `-Xlog:jni+resolve=debug` 实测区分。
3. **JNI 入口在 `prims/jvm.cpp`**：方法名规则 `JVM_<方法名>`，如 `hashCode` → `JVM_IHashCode`。
4. **看是否有 intrinsic**：类声明处 `@IntrinsicCandidate` 注解即线索，C2 实现看 `opto/library_call.cpp`。
5. **native ↔ C++ 映射需要自己记**：IDE 跳转不到，靠"类名 → 文件名"的规律（如 `Object` → `synchronizer.cpp` / `oop.cpp`）。
6. **深度追问用 `-XX:` 开关**：很多行为都有 flag 可切换，配合自己编的 `images/jdk` 做实验验证。

## 待跟进主题（候选）

- [x] `synchronized` 锁升级 → 已纳入 [关键字系列](keywords/README.md) 深读主线（衔接 Object 06 的 `inflate_locked_or_imse`）
- [x] `String.intern()` → 字符串表（`stringTable.cpp`）——未动，仍在候选
- [x] 双亲委派 → 已纳入[类加载系列](classload/README.md)（站①加载与双亲委派 + 站②链接 + 站③初始化与卸载，三站收官）
- [ ] G1 GC 年轻代回收（`g1CollectedHeap.cpp`）
- [ ] Java mirror 与 `Class` 对象 → 从 Object 02 的 `java_mirror` 下钻 `javaClasses.cpp`
- [ ] Valhalla value class 对象模型 → 从 Object 03 的 `jvm.cpp:793` 分支下钻
