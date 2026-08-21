# 类加载源码跟读系列

> 起点：`ClassLoader.loadClass` —— 一个类从字节到可用的完整旅程
> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 阅读原则：所有行号均来自本仓库真实源码，可随时在 IDEA 中 `Ctrl+Shift+N` 跳转验证

---

## 为什么读类加载

JVM 规范把类生命周期切成 **加载 → 验证 → 准备 → 解析 → 初始化 → 使用 → 卸载** 五加两步。本系列三站把这套生命周期全部落到 HotSpot 源码：站①加载（双亲委派 + SystemDictionary 协调 + KlassFactory 工匠），站②链接（parse / verify / link / prepare + 懒解析），站③初始化与卸载（状态机 + `<clinit>` + 按加载器整批回收）。读完三站 = 拿到「一个类从 `0xCAFEBABE` 到被 GC 整批回收」的完整地图。

与[常量池系列](../constantpool/README.md)互为前后脚：常量池讲「表结构 + 解析」，类加载讲「读表、链接、初始化」的完整流程。

## 系列目录

| 编号 | 主题 | 核心链路 | 配套动画 | 状态 |
|---|---|---|---|---|
| [01](01-load-parent-delegation.md) | 加载与双亲委派 | `loadClass` :501/:546 → 加锁+查表 :549/:551 → 向上委派 :556 → `JVM_DefineClass` → `SystemDictionary::resolve_instance_class_or_null` :606 → `PlaceholderTable` 占位防循环 :225/:255 → `ClassLoader::load_class` :1100 → `KlassFactory` :172 → `create_instance_klass` :5304 | [🎬](01-load-parent-delegation-animation.html) | ✅ |
| [02](02-link-verify.md) | 链接三阶段 | `parse_stream` :6024（魔数/版本/常量池）→ `Verifier::verify` :183 → `link_class_impl` :1123（父类递归 :1150 / rewrite :1232 / link_methods :1238 / vtable+itable :1256）→ prepare 静态字段 :522 → 懒解析（`klass_at_impl` :631 / `resolve_invoke` :1715） | [🎬](02-link-verify-animation.html) | ✅ |
| [03](03-init-unload.md) | 初始化与卸载（收官） | 主动使用触发（`_new` :223 / 静态字段 :741 / 常量不触发）→ `initialize` :961 → `initialize_impl` :1417（init_lock :1436 / 等待 :1442 / 递归放行 :1454 / being_initialized :1498）→ 父类先行 :1539 → `call_class_initializer` :2019 → 成功 `fully_initialized` :1620 / 失败错误表 :1341 + `ExceptionInInitializerError` :1645 → 卸载 `do_unloading` :410 整批回收 | [🎬](03-init-unload-animation.html) | ✅ |

## 交互动画（自包含 HTML，零外部依赖）

| 动画 | 主题 | 步骤 | 操作 |
|---|---|---|---|
| [01-load-parent-delegation-animation.html](01-load-parent-delegation-animation.html) | 加载：双亲委派全链路 | 15 步 | Space 播放/暂停 · ← → 步进 · R 重置 |
| [02-link-verify-animation.html](02-link-verify-animation.html) | 链接：verify / link / prepare | 15 步 | 同上 |
| [03-init-unload-animation.html](03-init-unload-animation.html) | 初始化：`<clinit>` 的一生 + 卸载 | 15 步 | 同上 |

## 三站时序衔接

```
站① 加载     站② 链接                   站③ 初始化              卸载
loadClass → parse_stream → verify/link → initialize_impl →   do_unloading
(双亲委派)   (魔数/常量池)  (接线)        (状态机+<clinit>)    (按加载器整批)
   :546         :6024        :1123            :1417              :410
```

## 每篇文档的阅读模板

1. **快速概览**：一句话结论 + 阅读顺序
2. **核心文件索引**：`文件:行号` 锚点表
3. **编号小节**：Java 声明 → native 边界 → C++ 实现层 → 核心逻辑逐行
4. **原生框架 vs 封装层对照**：JVM 规范术语 vs HotSpot 实现
5. **行号速查附录**：想做什么 → 去哪看

## 待跟进主题（与类加载相关）

- [ ] `ClassLoader.loadClass` 的锁粒度 vs `SystemDictionary` 锁（并发加载同一类的完整竞争时序）
- [ ] CDS（`-Xshare:on`）下 `load_instance_class_impl` 的 shared class 分支（:1430-1440）
- [ ] 卸载后的 `ClassLoaderData` 复用与类重加载（agent 场景）
