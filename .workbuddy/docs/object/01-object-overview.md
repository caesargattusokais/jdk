# Object 总览：13 个方法全景与 native 绑定机制

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Object 源码跟读 · 第 01 篇（[回到系列索引](README.md)）

---

## 快速概览

- **一句话结论**：`Object` 是类继承树的根，JDK 28 里共 **13 个方法**——6 个 `native`（`getClass/hashCode/clone/notify/notifyAll/wait0`）、7 个纯 Java（构造器、`equals/toString`、三个 `wait` 重载、`finalize`）。6 个 native 方法正好覆盖 HotSpot 的**对象头、类镜像、对象复制、Monitor 监视器**四大核心。
- **JDK 28 最大变化**：`Object.java` 里**已经删掉了 `registerNatives()`**。6 个 native 中 5 个由 VM 启动早期**静态注册**（`javaClasses.cpp:92-104`），只有 `getClass` 走标准 JNI 名字解析。这是 JDK 8 → JDK 28 绑定机制的演进主线。
- **阅读顺序建议**：本篇总览 → 按方法逐个跟读（见系列 [README](README.md)）。

---

## 一、方法全景表

`src/java.base/share/classes/java/lang/Object.java`，JDK 28 共 708 行，13 个方法：

| # | 方法 | 类型 | 行号 | native 绑定方式 | 核心实现 |
|---|---|---|---|---|---|
| 1 | `Object()` 构造器 | Java | 68–69 | — | 空构造器（`@IntrinsicCandidate`） |
| 2 | `getClass()` | native final | 90–91 | JNI 名字解析 | libjava `Object.c:43` → `jni_GetObjectClass`（jni.cpp:1029） |
| 3 | `hashCode()` | native | 130–131 | VM 静态注册 | `JVM_IHashCode`（jvm.cpp:787）→ `FastHashCode`（synchronizer.cpp:678） |
| 4 | `equals(Object)` | Java | 195–197 | — | `return (this == obj);` 引用相等 |
| 5 | `clone()` | native protected | 277–278 | VM 静态注册 | `JVM_Clone`（jvm.cpp:859）浅拷贝 |
| 6 | `toString()` | Java | 311–313 | — | `getClass().getName() + "@" + Integer.toHexString(hashCode())` |
| 7 | `notify()` | native final | 355–356 | VM 静态注册 | `JVM_MonitorNotify`（jvm.cpp:847）→ `ObjectSynchronizer::notify` |
| 8 | `notifyAll()` | native final | 389–390 | VM 静态注册 | `JVM_MonitorNotifyAll`（jvm.cpp:853）→ `ObjectSynchronizer::notifyall` |
| 9 | `wait()` | Java final | 419–421 | — | `wait(0L)` |
| 10 | `wait(long)` | Java final | 453–469 | — | 虚拟线程分支 → `wait0(timeoutMillis)` |
| 11 | `wait0(long)` | native private final | 472 | VM 静态注册 | `JVM_MonitorWait`（jvm.cpp:841）→ `ObjectSynchronizer::wait` |
| 12 | `wait(long,int)` | Java final | 577–592 | — | 参数校验 + nanos 进位 → `wait(timeoutMillis)` |
| 13 | `finalize()` | Java protected | 705–706 | — | 空方法，`@Deprecated(forRemoval=true)`（JEP 421） |

三个细节值得注意：

1. **`wait0` 是 private 且 final**（471 行注释："final modifier so method not in vtable"）——不让它进虚表，防止子类覆盖，保证 `wait` 语义绝对统一。
2. **三个 `wait` 重载只有一个是 native**：`wait0(long)`。`wait()` 和 `wait(long)` 都是 Java 包装，`wait(long,int)` 只做参数校验（582–585 行 nanos 范围检查）和进位（587–589 行 `nanos > 0` 则 `timeoutMillis++`）。
3. **`finalize()` 已经是空方法**：JDK 18 起默认禁用，JDK 28 中 `Object.finalize` 本身什么都不做（见 [07](07-finalize.md)）。

## 二、类注释里藏着 JDK 28 的"预告"

`Object.java:36-57` 的类注释有一个 `preview-block`，这是 JDK 28 特有的 **Valhalla 项目**内容：

> When preview features are enabled, subclasses of `java.lang.Object` are either value classes or identity classes... It is not possible to synchronize on a value object. An attempt to synchronize on a value object causes `IdentityException`.

翻译成关键信息：

- JDK 28 引入了 **value class / value object**（无 identity 的对象）与 **identity class / identity object**（普通对象）的二分。
- **value object 不能 synchronized、不能作为 Reference 的 referent、`finalize` 永远不会被调用**。
- 这对后续读 Object 的方法有直接影响：`hashCode`（jvm.cpp:793 valhalla 分支）、`clone`（jvm.cpp:885 value 分支）都为此加了特判。

## 三、native 绑定机制演进（本篇重点）

### 3.1 JDK 8 时代：registerNatives 模式

JDK 8 的 `Object.java` 开头有：

```java
private static native void registerNatives();
static {
    registerNatives();
}
```

对应 C 侧（`Object.c`）用一张 `JNINativeMethod` 表把方法名→JVM 函数指针注册进 VM。这是**运行时、Java 触发的绑定**。

### 3.2 JDK 28 时代：VM 静态注册

JDK 28 的 `Object.java` **没有 `registerNatives`**。绑定改为 VM 启动早期完成：

**调用点** `src/hotspot/share/classfile/vmClasses.cpp:172`（`Object_klass` 解析完成后立即执行）：

```cpp
java_lang_Object::register_natives(CHECK);
```

**注册表** `src/hotspot/share/classfile/javaClasses.cpp:92-104`：

```cpp
// Register native methods of Object
void java_lang_Object::register_natives(TRAPS) {
  InstanceKlass* obj = vmClasses::Object_klass();
  Method::register_native(obj, vmSymbols::hashCode_name(),
                          vmSymbols::void_int_signature(), (address) &JVM_IHashCode, CHECK);
  Method::register_native(obj, vmSymbols::wait_name(),
                          vmSymbols::long_void_signature(), (address) &JVM_MonitorWait, CHECK);
  Method::register_native(obj, vmSymbols::notify_name(),
                          vmSymbols::void_method_signature(), (address) &JVM_MonitorNotify, CHECK);
  Method::register_native(obj, vmSymbols::notifyAll_name(),
                          vmSymbols::void_method_signature(), (address) &JVM_MonitorNotifyAll, CHECK);
  Method::register_native(obj, vmSymbols::clone_name(),
                          vmSymbols::void_object_signature(), (address) &JVM_Clone, THREAD);
}
```

**执行逻辑** `Method::register_native`（`oops/method.cpp:551`）：按 `名字+签名` 找到 `Method` 对象，直接 `method->set_native_function(entry)` 写入函数指针——**比 JNI 动态链接更早、更快，且不依赖导出符号**。

### 3.3 两个细节（容易踩坑）

**细节一：`wait_name` 的值是 `"wait0"` 不是 `"wait"`**

`src/hotspot/share/classfile/vmSymbols.hpp:462`：

```cpp
template(wait_name, "wait0")
```

因为 JDK 把真正的 native 方法改名成了 `wait0`（虚拟线程支持），符号表同步改名。注册时按名字+签名 `wait0(J)V` 精确命中。

**细节二：`getClass` 是例外——走 JNI 名字解析**

注册表里**没有** `getClass`。它由 libjava 的 `Object.c:43` 提供：

```c
JNIEXPORT jclass JNICALL
Java_java_lang_Object_getClass(JNIEnv *env, jobject this) {
    if (this == NULL) {
        JNU_ThrowNullPointerException(env, NULL);
        return 0;
    } else {
        return (*env)->GetObjectClass(env, this);
    }
}
```

即标准 JNI 名称解析（`Java_java_lang_Object_getClass` → `env->GetObjectClass` → JNI 函数表 → `jni_GetObjectClass`，jni.cpp:1029）。这也是 libjava 里**仅存的** Object native 实现。

### 3.4 实证：-Xlog:jni+resolve 日志

用编译产物跑一个触发所有 Object native 方法的程序，开 `-Xlog:jni+resolve=debug`：

```
[0.030s][debug][jni,resolve] [Registering JNI native method java.lang.Object.hashCode]
[0.030s][debug][jni,resolve] [Registering JNI native method java.lang.Object.wait0]
[0.030s][debug][jni,resolve] [Registering JNI native method java.lang.Object.notify]
[0.030s][debug][jni,resolve] [Registering JNI native method java.lang.Object.notifyAll]
[0.030s][debug][jni,resolve] [Registering JNI native method java.lang.Object.clone]
[0.032s][debug][jni,resolve] [Dynamic-linking native method java.lang.System.registerNatives ... JNI]
```

对比非常清晰：

- **Object 的 5 个方法**：`Registering JNI native method`——VM 静态注册（0.030s，启动早期）；
- **System.registerNatives**：`Dynamic-linking`——JNI 动态链接（0.032s，稍晚，且仍保留老的 registerNatives 模式）。

## 四、Object 方法全景链路图

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 900 720" role="img" font-family="'Segoe UI', 'Microsoft YaHei', sans-serif">
<title>Object 方法全景链路图</title>
<desc>Object 的 6 个 native 方法与 7 个纯 Java 方法在 HotSpot 中的实现落点</desc>
<defs>
  <marker id="arrO" markerWidth="9" markerHeight="9" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="#888780"/></marker>
</defs>
<style>
  .card{stroke-width:1.5}
  .t{font-size:15px;font-weight:bold}
  .s{font-size:12px;font-family:Consolas,monospace}
  .lab{font-size:12px;fill:#5F5E5A}
</style>

<!-- 顶部：Object 本体 -->
<rect x="270" y="30" width="360" height="74" rx="14" fill="#FAEEDA" stroke="#BA7517" stroke-width="2"/>
<text x="450" y="58" text-anchor="middle" fill="#633806" class="t">java.lang.Object（JDK 28）</text>
<text x="450" y="78" text-anchor="middle" fill="#854F0B" class="s">Object.java  ·  13 个方法</text>
<text x="450" y="95" text-anchor="middle" fill="#854F0B" class="s">6 native + 7 纯 Java</text>

<!-- 左列：native 方法 -->
<rect x="40" y="150" width="230" height="42" rx="10" fill="#E6F1FB" stroke="#185FA5"/>
<text x="155" y="169" text-anchor="middle" fill="#0C447C" class="t">getClass()</text>
<text x="155" y="185" text-anchor="middle" fill="#185FA5" class="s">Object.java:90</text>
<rect x="40" y="210" width="230" height="42" rx="10" fill="#E6F1FB" stroke="#185FA5"/>
<text x="155" y="229" text-anchor="middle" fill="#0C447C" class="t">hashCode()</text>
<text x="155" y="245" text-anchor="middle" fill="#185FA5" class="s">Object.java:130</text>
<rect x="40" y="270" width="230" height="42" rx="10" fill="#E6F1FB" stroke="#185FA5"/>
<text x="155" y="289" text-anchor="middle" fill="#0C447C" class="t">clone()</text>
<text x="155" y="305" text-anchor="middle" fill="#185FA5" class="s">Object.java:277</text>
<rect x="40" y="330" width="230" height="42" rx="10" fill="#E6F1FB" stroke="#185FA5"/>
<text x="155" y="349" text-anchor="middle" fill="#0C447C" class="t">wait0(long)</text>
<text x="155" y="365" text-anchor="middle" fill="#185FA5" class="s">Object.java:472</text>
<rect x="40" y="390" width="230" height="42" rx="10" fill="#E6F1FB" stroke="#185FA5"/>
<text x="155" y="409" text-anchor="middle" fill="#0C447C" class="t">notify() / notifyAll()</text>
<text x="155" y="425" text-anchor="middle" fill="#185FA5" class="s">Object.java:355 / 389</text>

<!-- 中间：绑定层 -->
<rect x="335" y="160" width="230" height="62" rx="10" fill="#EEEDFE" stroke="#534AB7"/>
<text x="450" y="185" text-anchor="middle" fill="#3C3489" class="t">JNI 名字解析</text>
<text x="450" y="203" text-anchor="middle" fill="#534AB7" class="s">Object.c:43 → GetObjectClass</text>
<rect x="335" y="240" width="230" height="62" rx="10" fill="#EEEDFE" stroke="#534AB7"/>
<text x="450" y="265" text-anchor="middle" fill="#3C3489" class="t">VM 静态注册表</text>
<text x="450" y="283" text-anchor="middle" fill="#534AB7" class="s">javaClasses.cpp:92-104</text>
<text x="450" y="298" text-anchor="middle" fill="#534AB7" class="s">调用点 vmClasses.cpp:172</text>
<rect x="335" y="330" width="230" height="62" rx="10" fill="#EEEDFE" stroke="#534AB7"/>
<text x="450" y="355" text-anchor="middle" fill="#3C3489" class="t">VM 静态注册表</text>
<text x="450" y="373" text-anchor="middle" fill="#534AB7" class="s">wait_name = "wait0"</text>
<text x="450" y="388" text-anchor="middle" fill="#534AB7" class="s">vmSymbols.hpp:462</text>

<!-- 右列：实现落点 -->
<rect x="630" y="150" width="230" height="52" rx="10" fill="#EAF3DE" stroke="#3B6D11"/>
<text x="745" y="172" text-anchor="middle" fill="#27500A" class="t">jni_GetObjectClass</text>
<text x="745" y="190" text-anchor="middle" fill="#3B6D11" class="s">jni.cpp:1029 → java_mirror</text>
<rect x="630" y="222" width="230" height="52" rx="10" fill="#EAF3DE" stroke="#3B6D11"/>
<text x="745" y="244" text-anchor="middle" fill="#27500A" class="t">JVM_IHashCode</text>
<text x="745" y="262" text-anchor="middle" fill="#3B6D11" class="s">jvm.cpp:787 → FastHashCode</text>
<rect x="630" y="294" width="230" height="52" rx="10" fill="#EAF3DE" stroke="#3B6D11"/>
<text x="745" y="316" text-anchor="middle" fill="#27500A" class="t">JVM_Clone</text>
<text x="745" y="334" text-anchor="middle" fill="#3B6D11" class="s">jvm.cpp:859 浅拷贝</text>
<rect x="630" y="366" width="230" height="52" rx="10" fill="#EAF3DE" stroke="#3B6D11"/>
<text x="745" y="388" text-anchor="middle" fill="#27500A" class="t">JVM_MonitorWait</text>
<text x="745" y="406" text-anchor="middle" fill="#3B6D11" class="s">jvm.cpp:841 → ObjectMonitor</text>
<rect x="630" y="438" width="230" height="52" rx="10" fill="#EAF3DE" stroke="#3B6D11"/>
<text x="745" y="460" text-anchor="middle" fill="#27500A" class="t">JVM_MonitorNotify(All)</text>
<text x="745" y="478" text-anchor="middle" fill="#3B6D11" class="s">jvm.cpp:847 / 853</text>

<!-- 连线 -->
<line x1="270" y1="160" x2="335" y2="186" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>
<line x1="270" y1="228" x2="335" y2="264" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>
<line x1="270" y1="290" x2="335" y2="300" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>
<line x1="270" y1="355" x2="335" y2="358" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>
<line x1="270" y1="405" x2="335" y2="370" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>
<line x1="565" y1="186" x2="630" y2="176" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>
<line x1="565" y1="262" x2="630" y2="248" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>
<line x1="565" y1="300" x2="630" y2="320" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>
<line x1="565" y1="360" x2="630" y2="392" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>
<line x1="565" y1="374" x2="630" y2="464" class="lab" stroke="#888780" stroke-width="1.5" marker-end="url(#arrO)"/>

<!-- 底部：纯 Java 方法 -->
<rect x="120" y="520" width="200" height="58" rx="10" fill="#FAEEDA" stroke="#BA7517"/>
<text x="220" y="545" text-anchor="middle" fill="#633806" class="t">equals()</text>
<text x="220" y="563" text-anchor="middle" fill="#854F0B" class="s">Object.java:195  ==</text>
<rect x="350" y="520" width="200" height="58" rx="10" fill="#FAEEDA" stroke="#BA7517"/>
<text x="450" y="545" text-anchor="middle" fill="#633806" class="t">toString()</text>
<text x="450" y="563" text-anchor="middle" fill="#854F0B" class="s">Object.java:311</text>
<rect x="580" y="520" width="200" height="58" rx="10" fill="#FAEEDA" stroke="#BA7517"/>
<text x="680" y="545" text-anchor="middle" fill="#633806" class="t">wait() 三连 + finalize()</text>
<text x="680" y="563" text-anchor="middle" fill="#854F0B" class="s">Object.java:419/453/577/705</text>

<line x1="350" y1="120" x2="280" y2="520" stroke="#888780" stroke-width="1.3" stroke-dasharray="5,4" marker-end="url(#arrO)"/>
<line x1="450" y1="120" x2="400" y2="520" stroke="#888780" stroke-width="1.3" stroke-dasharray="5,4" marker-end="url(#arrO)"/>
<line x1="560" y1="120" x2="620" y2="520" stroke="#888780" stroke-width="1.3" stroke-dasharray="5,4" marker-end="url(#arrO)"/>

<text x="450" y="650" text-anchor="middle" fill="#5F5E5A" class="lab">橙 = Java 声明 / 蓝 = native 声明 · JNI 层 / 紫 = 绑定机制 / 绿 = HotSpot 实现落点</text>
<text x="450" y="672" text-anchor="middle" fill="#5F5E5A" class="lab">虚线 = 纯 Java 包装（无 native）  ·  实线 = native 绑定路径</text>
</svg>

## 五、读这一篇能记住的三件事

1. **Object 的 6 个 native 方法 = 4 个 JVM 子系统入口**：对象头（hashCode）、类镜像（getClass）、对象复制（clone）、Monitor（wait/notify/notifyAll）。
2. **JDK 28 已淘汰 Object 的 registerNatives**：绑定提前到 VM 启动早期（vmClasses.cpp:172），由 `javaClasses.cpp:92-104` 静态注册，`wait_name` 的符号名已改成 `"wait0"`。只有 `getClass` 保留 JNI 名字解析。
3. **value class（Valhalla）已经渗透到 Object 语义**：类注释、hashCode、clone 都有 value 分支——这是 JDK 28 读源码时绕不开的新维度。

## 附录：一句话索引

| 我想…… | 去哪里 |
|---|---|
| 看全部 13 个方法 | `Object.java`（共 708 行） |
| 看 native 绑定注册表 | `javaClasses.cpp:92-104` + `vmClasses.cpp:172` |
| 验证绑定是静态注册还是动态链接 | `java -Xlog:jni+resolve=debug` |
| 为什么 wait 的 native 叫 wait0 | `vmSymbols.hpp:462` + `Object.java:453-472` |
| 读某个方法的实现 | 见系列 [README](README.md) 目录表 |
