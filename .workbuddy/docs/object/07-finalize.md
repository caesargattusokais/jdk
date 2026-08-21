# finalize()：一个正在退出历史舞台的方法

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Object 源码跟读 · 第 07 篇（[回到系列索引](README.md)）
> 主题：`Object.finalize()` 的空实现、JEP 421 废弃史，以及 JDK 28 里的 finalization 开关

---

## 快速概览

- **一句话结论**：`Object.finalize()` 是**空方法**（`{ }`），带 `@Deprecated(since="9", forRemoval=true)`。它曾经的语义是"GC 回收前回调"，但 JEP 421（JDK 18）正式弃用整个 finalization 机制，JDK 28 通过 `--finalization=disabled|enabled` 开关控制（**默认 enabled**，`instanceKlass.cpp:204`）。
- **JDK 28 现状**：finalization 机制代码仍在（`FinalizerThread`、`register_finalizer`），但已被官方宣判死刑——新代码一律用 `Cleaner`/`PhantomReference`/`try-with-resources`。
- **阅读顺序建议**：`Object.java:705` → `instanceKlass.cpp:204` → `arguments.cpp:2451` → `jvm.cpp:918`。

### 核心文件索引

| 文件 | 关键行 | 内容 |
|---|---|---|
| `src/java.base/share/classes/java/lang/Object.java` | 705–706 | `finalize` 空实现 + `@Deprecated(forRemoval=true)` |
| `src/java.base/share/classes/java/lang/Object.java` | 610–614 / 682–698 | javadoc：禁用时永不调用 / JEP 421 讨论 |
| `src/hotspot/share/oops/instanceKlass.cpp` | 204 | `_finalization_enabled = true`（默认启用） |
| `src/hotspot/share/runtime/arguments.cpp` | 2451–2458 | `--finalization=enabled\|disabled` 开关 |
| `src/hotspot/share/classfile/classFileParser.cpp` | 2830 / 4164 | 加载时按开关决定是否处理 finalizer |
| `src/hotspot/share/prims/jvm.cpp` | 918–924 | `JVM_ReportFinalizationComplete` / `JVM_IsFinalizationEnabled` |
| `src/hotspot/share/prims/jvm.cpp` | 907–909 | `clone` 时按需 `register_finalizer` |

---

## 一、Java 层：空方法与它的"墓志铭"

`Object.java:705-706`——整个方法的实现只有一行：

```java
@Deprecated(since="9", forRemoval=true)
protected void finalize() throws Throwable { }
```

但挂在它上面的 javadoc（594–704 行）信息量巨大：

1. **610–614 行的"免责声明"**（JEP 421 后新增）：

> When running in a Java virtual machine in which finalization has been disabled or removed, the garbage collector will never call `finalize()` for any object. In a Java virtual machine in which finalization is enabled, the garbage collector might call `finalize` only after an indefinite delay.

——"可能调用，且时间不定"。这是对 finalization 不可预测性的官方承认。

2. **682–698 行的 @deprecated 标记**（JDK 18 重写）：

> Finalization is deprecated and subject to removal in a future release. The use of finalization can lead to problems with security, performance, and reliability. See JEP 421.

并明确给出替代方案（690–695 行）：**`java.lang.ref.Cleaner`、`PhantomReference`、`AutoCloseable` + try-with-resources**。

3. **类注释的 value class 补充**（50–51 行）：value class 的 finalize **永远不会**被 GC 调用（Valhalla 语义）。

## 二、为什么 finalize 没有 native 实现

它不需要。finalization 的机制不在方法本身，而在 **GC 与 Reference 处理**：

- `Object.finalize()` 只是个"钩子"（空壳）；
- 真正的调用链是：GC 判定对象不可达 → 如果类 `has_finalizer()` → 对象被放进 `java.lang.ref.Finalizer` 的引用队列 → 守护线程 `FinalizerThread` 出队并反射调用 `finalize()`。

所以 hotspot 里跟 finalize 相关的代码都在"类加载"和"引用处理"侧：

- **类加载时**：`classFileParser.cpp:2830/4164` 检查 `is_finalization_enabled()`，决定是否标记 finalizer（`has_finalizer`）；
- **clone 时**：`jvm.cpp:907-909` 新对象如果 `has_finalizer()` 要 `register_finalizer`；
- **上报**：`jvm.cpp:918-924` 提供 `JVM_ReportFinalizationComplete`（FinalizerThread 调完回调用）和 `JVM_IsFinalizationEnabled`。

## 三、JEP 421 时间线与 JDK 28 开关

**时间线**（以本仓库源码为准）：

| 版本 | 事件 |
|---|---|
| JDK 9 | 标记 `@Deprecated`（只是警告） |
| JDK 18 | **JEP 421**：正式弃用 finalization，引入开关，文档全面改写 |
| JDK 28 | 开关演化为 `--finalization=enabled\|disabled`，**默认 enabled** |

JDK 28 的开关实现 `arguments.cpp:2451-2458`：

```cpp
} else if (match_option(option, "--finalization=", &tail)) {
  if (strcmp(tail, "enabled") == 0) {
    InstanceKlass::set_finalization_enabled(true);
  } else if (strcmp(tail, "disabled") == 0) {
    InstanceKlass::set_finalization_enabled(false);
  } else {
    jio_fprintf(defaultStream::error_stream(),
                "Invalid finalization value '%s', must be 'disabled' or 'enabled'.\n", tail);
    return JNI_EINVAL;
  }
}
```

默认值 `instanceKlass.cpp:204`：

```cpp
bool InstanceKlass::_finalization_enabled = true;
```

注意：**默认是启用的**（为存量代码保留兼容）。但无论开关如何，`Object.finalize()` 本身都是空方法——**类必须自己 override 才有意义**，而官方强烈建议不要再 override。

## 四、验证实验

```bash
# 看默认状态（应输出 true）
D:\project\jdk\build\windows-x86_64-server-release\images\jdk\bin\java.exe -Xlog:class+load -version 2>&1 | head -2

# 显式关闭 finalization
D:\project\jdk\build\windows-x86_64-server-release\images\jdk\bin\java.exe --finalization=disabled -version
```

写一个验证"finalize 是否被调用"的小程序：

```java
public class F {
    @Override protected void finalize() { System.out.println("finalized!"); }
    public static void main(String[] a) throws Exception {
        new F();
        System.gc();
        Thread.sleep(1000);   // 给 FinalizerThread 时间
    }
}
```

```bash
# 默认（enabled）：可能打印 finalized!（GC 时机不定，不可依赖）
java F
# 关闭后：永不打印
java --finalization=disabled F
```

## 附录：一句话索引

| 我想…… | 去哪里 |
|---|---|
| 看 finalize 空实现 | `Object.java:705-706` |
| 看 JEP 421 讨论 | `Object.java:682-698` |
| 看默认开关值 | `instanceKlass.cpp:204` |
| 看开关解析 | `arguments.cpp:2451-2458` |
| 看 clone 时 finalizer 注册 | `jvm.cpp:907-909` |
| 用替代方案 | `java.lang.ref.Cleaner`（JDK 9+） |
