# Object 源码跟读系列

> 起点：`java.lang.Object` —— 一切 Java 对象的祖先
> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 阅读原则：所有行号均来自本仓库真实源码，可随时在 IDEA 中 `Ctrl+Shift+N` 跳转验证

---

## 为什么先读 Object

`Object` 是类继承树的根，它身上的 6 个 native 方法正好覆盖了 **HotSpot 三大核心子系统**：

| 子系统 | Object 里的代表方法 | 跟读文档 |
|---|---|---|
| 对象头 / 身份信息 | `hashCode()` | [03](03-hashCode.md) |
| 对象模型 / 类镜像 | `getClass()` | [02](02-getClass.md) |
| 对象复制 | `clone()` | [04](04-clone.md) |
| 监视器 Monitor | `wait0()` / `notify()` / `notifyAll()` | [06](06-wait-notify.md) |

把 Object 读透 = 一次性拿到读 JVM 的三张地图（对象头、类镜像、Monitor），后续无论读 `String`、`Thread` 还是 `ClassLoader`，都能随时回踩这些地基。

## 系列目录

| 编号 | 主题 | 核心链路 | 配套动画 | 状态 |
|---|---|---|---|---|
| [01](01-object-overview.md) | Object 总览 | 13 个方法全景 + native 绑定机制演进（registerNatives 的消失） | — | ✅ |
| [02](02-getClass.md) | `getClass()` | libjava JNI → `jni_GetObjectClass` → Java mirror | — | ✅ |
| [03](03-hashCode.md) | `hashCode()` 身份哈希 | VM 注册 → `JVM_IHashCode` → `FastHashCode` → mark word CAS | [🎬](03-hashCode-markword-animation.html) | ✅ |
| [04](04-clone.md) | `clone()` 浅拷贝 | VM 注册 → `JVM_Clone` → 分配 + `HeapAccess::clone` + finalizer | [🎬](04-clone-shallowcopy-animation.html) | ✅ |
| [05](05-equals-toString.md) | `equals()` / `toString()` | 纯 Java：引用相等 / `类名@hash` | — | ✅ |
| [06](06-wait-notify.md) | `wait()` / `notify()` / `notifyAll()` | `wait0` → `JVM_MonitorWait` → 锁膨胀 → `ObjectMonitor` | [🎬](06-wait-notify-monitor-animation.html) | ✅ |
| [07](07-finalize.md) | `finalize()` | 空方法 + JEP 421 废弃史 | — | ✅ |

## 交互动画（自包含 HTML，零外部依赖）

| 动画 | 主题 | 步骤 | 操作 |
|---|---|---|---|
| [03-hashCode-markword-animation.html](03-hashCode-markword-animation.html) | mark word 安装 identity hash | 8 步 | Space 播放/暂停 · ← → 步进 · R 重置 |
| [04-clone-shallowcopy-animation.html](04-clone-shallowcopy-animation.html) | clone 浅拷贝：分配 + 逐字段拷贝 | 9 步 | 同上 |
| [06-wait-notify-monitor-animation.html](06-wait-notify-monitor-animation.html) | 锁膨胀 + ObjectMonitor 队列流转 | 12 步 | 同上 |

## 每篇文档的阅读模板

1. **快速概览**：一句话结论 + 阅读顺序
2. **核心文件索引**：`文件:行号` 锚点表
3. **编号小节**：Java 声明 → 绑定机制 → JNI/实现层 → 核心逻辑逐行
4. **验证实验**：用 `images\jdk\bin\java.exe` 实测
5. **一句话索引附录**：想做什么 → 去哪看

## 验证环境

```bash
# 已编译产物（编译方法见项目记忆）
D:\project\jdk\build\windows-x86_64-server-release\images\jdk\bin\java.exe -version
```

## 待跟进主题（与 Object 相关）

- [ ] synchronized 锁升级全流程（从本篇 06 的 `inflate_locked_or_imse` 下钻 `ObjectMonitor`）
- [ ] `ObjectMonitor::wait` 的等待队列（ObjectWaiter 链表 + 超时唤醒）
- [ ] Java mirror 与 `Class` 对象的双向引用（从本篇 02 下钻 `javaClasses.cpp`）
- [ ] Valhalla value class 的对象模型（从本篇 03 的 793-822 分支下钻）
