# getClass()：运行时类与 Java Mirror

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Object 源码跟读 · 第 02 篇（[回到系列索引](README.md)）
> 主题：`Object.getClass()` 如何拿到运行时类的 `Class` 对象

---

## 快速概览

- **一句话结论**：`getClass()` 是 Object 6 个 native 方法里**唯一走标准 JNI 名字解析**的（其余 5 个由 VM 静态注册）。链路为 `Object.c`（libjava）→ `env->GetObjectClass` → `jni_GetObjectClass` → 取 `Klass` 的 **Java mirror**（`_java_mirror` 字段）。
- **核心概念**：HotSpot 里每个 Java 类有两份"身份"——C++ 侧的 `Klass`（元数据）和 Java 侧的 `Class` 对象（mirror，由 `_java_mirror` 字段指向）。`getClass()` 干的事就是**从对象拿到 Klass，再从 Klass 拿到 mirror**。
- **JIT 路径**：`@IntrinsicCandidate` 使 C2 编译后直接内联为 `load_object_klass` + `load_mirror_from_klass` 两个节点，省掉整条 JNI 调用。
- **阅读顺序建议**：`Object.java` → `Object.c` → `jni.cpp` → `klass.inline.hpp` → `library_call.cpp`。

### 核心文件索引

| 文件 | 关键行 | 内容 |
|---|---|---|
| `src/java.base/share/classes/java/lang/Object.java` | 90–91 | `getClass` 声明（`native` + `final` + `@IntrinsicCandidate`） |
| `src/java.base/share/native/libjava/Object.c` | 40–48 | JNI 实现 `Java_java_lang_Object_getClass` |
| `src/hotspot/share/prims/jni.cpp` | 1028–1037 | JNI 函数表实现 `jni_GetObjectClass` |
| `src/hotspot/share/oops/klass.inline.hpp` | 96–98 | `Klass::java_mirror()` 返回 mirror |
| `src/hotspot/share/opto/library_call.cpp` | 254 / 5803 | C2 intrinsic 分发 / 内联实现 |

---

## 一、Java 层声明

`Object.java:90-91`：

```java
@IntrinsicCandidate
public final native Class<?> getClass();
```

- **`final`**：不允许子类覆盖（运行时类型由 VM 决定，覆盖没有意义）。
- **`@IntrinsicCandidate`**：JIT 热点时会被 C2 内联替换。
- **泛型 `Class<?>`**：返回值是"运行时类的 Class 对象"——注意它**不是**编译期静态类型，所以 76–84 行注释特意强调 `Class<? extends Number> c = n.getClass();` 无需强转。

## 二、JNI 路径：libjava 层（唯一的 JNI 名字解析）

JDK 28 中 `getClass` 不在 VM 注册表里（见总览 [3.2 节](01-object-overview.md)），它由 libjava 提供，`src/java.base/share/native/libjava/Object.c:40-48`：

```c
JNIEXPORT jclass JNICALL
Java_java_lang_Object_getClass(JNIEnv *env, jobject this)
{
    if (this == NULL) {
        JNU_ThrowNullPointerException(env, NULL);
        return 0;
    } else {
        return (*env)->GetObjectClass(env, this);
    }
}
```

要点：

- 函数名 `Java_java_lang_Object_getClass` 完全符合 JNI 名称解析规则（nativeLookup.cpp 里的映射表），**不需要注册表**。
- **null 检查在这层做**：`getClass()` 的 NPE 从这里抛出。
- 真正的活儿交给 JNI 函数表里的 `GetObjectClass`。

## 三、JNI 函数表：jni_GetObjectClass

`src/hotspot/share/prims/jni.cpp:1028-1037`：

```cpp
JNI_ENTRY(jclass, jni_GetObjectClass(JNIEnv *env, jobject obj))
  HOTSPOT_JNI_GETOBJECTCLASS_ENTRY(env, obj);

  Klass* k = JNIHandles::resolve_non_null(obj)->klass();   // ① 对象 → Klass
  jclass ret =
    (jclass) JNIHandles::make_local(THREAD, k->java_mirror());  // ② Klass → mirror

  HOTSPOT_JNI_GETOBJECTCLASS_RETURN(ret);
  return ret;
JNI_END
```

**就两行核心代码，信息量极大**：

1. **① 对象 → Klass**：`JNIHandles::resolve_non_null(obj)` 把 JNI 句柄解析成 `oop`（对象指针），`oop->klass()` 从**对象头**取出指向 `Klass` 的指针（对象头的 klass 指针位）。
2. **② Klass → Java mirror**：`k->java_mirror()` 返回这个类在 Java 侧的 `Class` 对象。`make_local` 把它包装成 JNI 局部引用返回。

## 四、核心概念：Klass vs Java mirror

`Klass::java_mirror()` 的实现 `src/hotspot/share/oops/klass.inline.hpp:96-98`：

```cpp
// Loading the java_mirror does not keep its holder alive. See Klass::keep_alive().
inline oop Klass::java_mirror() const {
  return _java_mirror.resolve();
}
```

`_java_mirror` 是 `Klass` 的一个字段（`OopHandle`），在类加载时由 VM 创建 `java.lang.Class` 实例并写入。

**这份"双身份"设计是整个 JVM 对象模型的地基**：

| | C++ 侧 | Java 侧 |
|---|---|---|
| 类元数据 | `Klass`（含 `_java_mirror` 字段） | `java.lang.Class` 实例 |
| 谁持有 | 元空间（Metaspace） | Java 堆 |
| 关系 | Klass 1:1 持有 mirror 引用 | mirror 也持有 Klass（`Class` 的 native 字段） |

所以 `o.getClass()` 拿到的 `Class` 对象，本质是**指向那个类的 C++ 元数据在 Java 堆里的投影**。`Class` 类的源码 `src/java.base/share/classes/java/lang/Class.java` 开头那段"Type parameters"注释（`<T> The type of the class modeled by this Class object`）说的就是这件事。

## 五、JIT intrinsic 路径（编译后）

C2 分发 `src/hotspot/share/opto/library_call.cpp:254`：

```cpp
case vmIntrinsics::_getClass:                 return inline_native_getClass();
```

内联实现 `library_call.cpp:5803-5819`（节选）：

```cpp
bool LibraryCallKit::inline_native_getClass() {
  Node* obj = argument(0);
  if (obj->is_InlineType()) {
    // inline class 分支：直接用类型信息取 mirror
    set_result(makecon(TypeInstPtr::make(t->inline_klass()->java_mirror())));
    return true;
  }
  obj = null_check_receiver();
  set_result(load_mirror_from_klass(load_object_klass(obj)));   // 核心
  return true;
}
```

- 普通对象：**`load_object_klass(obj)` 读对象头的 klass 指针 → `load_mirror_from_klass` 读 `_java_mirror`**——和解释路径完全同构，但全部编译成机器码，无 JNI 栈帧开销。
- inline class 分支：编译期类型已知，直接常量折叠成 mirror（`makecon`）。

## 六、验证实验

用编译产物验证（也可加 `-Xlog:jni+resolve=debug` 看绑定日志）：

```java
public class G {
    public static void main(String[] a) {
        Number n = 0;                     // 静态类型 Number
        Class<? extends Number> c = n.getClass();   // 运行时类型 Integer，无需强转
        System.out.println(c.getName());  // java.lang.Integer
        System.out.println(c == int.class);          // false
        System.out.println(Integer.class == int.class); // false（包装类 vs 基本类型）
    }
}
```

```bash
D:\project\jdk\build\windows-x86_64-server-release\images\jdk\bin\java.exe G
```

## 附录：一句话索引

| 我想…… | 去哪里 |
|---|---|
| 看 getClass 的 JNI 实现 | `Object.c:40-48` |
| 看 JNI 函数表实现 | `jni.cpp:1028-1037` |
| 理解 mirror 存哪 | `klass.inline.hpp:96` + `_java_mirror` 字段 |
| 看 C2 内联 | `library_call.cpp:5803-5819` |
| 验证 JIT 生效 | `-XX:+PrintInlining` 搜 `getClass` |
