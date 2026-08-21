# clone()：JVM 眼中的"浅拷贝"

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Object 源码跟读 · 第 04 篇（[回到系列索引](README.md)）
> 主题：`Object.clone()` 从 Cloneable 检查到分配、拷贝、finalizer 注册的完整流程

---

## 快速概览

- **一句话结论**：`clone()` 是 VM 静态注册的 native（绑定 `JVM_Clone`），干三件事——**检查 `Cloneable` → 按对象头里的 klass 分配一块同样大小的新对象 → 用 `HeapAccess::clone` 逐字段浅拷贝**。value class 例外：无 identity，直接返回自身。
- **"浅"在哪**：只拷贝对象本身的字段值（引用照抄），**不递归拷贝引用指向的对象**——注释原话 "the contents of the fields are not themselves cloned"（Object.java:258）。
- **两个隐藏点**：① 数组全部视为 Cloneable（JLS 20.1.5）；② `Reference` 的子类**不可克隆**（880 行特判）。
- **阅读顺序建议**：`Object.java` → `javaClasses.cpp`（绑定）→ `jvm.cpp:859` `JVM_Clone`（重点）→ `barrierSet.hpp`。

### 配套交互动画

▶ ** [04-clone-shallowcopy-animation.html](04-clone-shallowcopy-animation.html)** —— clone 浅拷贝 9 步动画：
Cloneable 检查 → value class 分支 → 分配新对象 → `HeapAccess::clone` 逐字段拷贝（`id: 0→42` 值拷贝、`arr` 引用照抄共享同一数组）→ finalizer 检查。直观展示 `c.arr == d.arr` 为什么是 `true`。

### 核心文件索引

| 文件 | 关键行 | 内容 |
|---|---|---|
| `src/java.base/share/classes/java/lang/Object.java` | 277–278 | `clone` 声明（`native` + `protected` + `@IntrinsicCandidate`） |
| `src/hotspot/share/classfile/javaClasses.cpp` | 102–103 | 绑定注册（`clone` → `JVM_Clone`） |
| `src/hotspot/share/prims/jvm.cpp` | 859–914 | `JVM_Clone` 完整实现（本篇重点） |
| `src/hotspot/share/gc/shared/barrierSet.hpp` | 312 | `clone_in_heap`（GC 屏障感知的拷贝） |

---

## 一、Java 层声明

`Object.java:277-278`：

```java
@IntrinsicCandidate
protected native Object clone() throws CloneNotSupportedException;
```

三个信息量：

- **`protected`**：只有子类能调，且子类通常通过 `super.clone()` 调用。246–267 行 `@implSpec` 长篇说明了约定（`x.clone() != x`、`x.clone().getClass() == x.getClass()`）。
- **`throws CloneNotSupportedException`**：检查型异常——类不实现 `Cloneable` 时由 JVM 抛出。
- **`@IntrinsicCandidate`**：C2 会尝试内联成分配+拷贝的机器码（解释路径的语义完全一致）。

## 二、绑定与入口

注册表 `javaClasses.cpp:102-103`：

```cpp
Method::register_native(obj, vmSymbols::clone_name(),
                        vmSymbols::void_object_signature(), (address) &JVM_Clone, THREAD);
```

签名 `()Ljava/lang/Object;` 精确命中 `clone()`。实现本体 `jvm.cpp:859-914`，按执行顺序拆解：

## 三、第一步：Cloneable 检查（875–883）

```cpp
// Check if class of obj supports the Cloneable interface.
// All arrays are considered to be cloneable (See JLS 20.1.5).
// All j.l.r.Reference classes are considered non-cloneable.
if (!klass->is_cloneable() ||
    (klass->is_instance_klass() &&
     InstanceKlass::cast(klass)->reference_type() != REF_NONE)) {
  ResourceMark rm(THREAD);
  THROW_MSG_NULL(vmSymbols::java_lang_CloneNotSupportedException(), klass->external_name());
}
```

- `is_cloneable()`：**类加载时**由 VM 算好的标志位（类实现 `Cloneable` 即置位，864–873 行 ASSERT 专门校验这个标志的正确性）。
- **Reference 子类特判**：`reference_type() != REF_NONE`（软/弱/虚引用）一律拒绝——否则 clone 一个 `WeakReference` 会破坏引用语义。

## 四、第二步：value class 直接返回自身（885–889）

```cpp
if (klass->is_inline_klass()) {
  // Value instances have no identity, so return the current instance instead of allocating a new one
  // Value classes cannot have finalizers, so the method can return immediately
  return JNIHandles::make_local(THREAD, obj());
}
```

**JDK 28（Valhalla）新增**：value object 没有 identity，`clone` 语义退化为"复制不可区分"，直接返回原对象即可。这正是系列总览里类注释"value class 的 clone 可能与原对象不可区分"的实现。

## 五、第三步：分配 + 浅拷贝（891–902）

```cpp
// Make shallow object copy
const size_t size = obj->size();                       // 按 klass 计算对象大小
oop new_obj_oop = nullptr;
if (obj->is_array()) {
  const int length = ((arrayOop)obj())->length();
  new_obj_oop = Universe::heap()->array_allocate(klass, size, length,
                                                 /* do_zero */ true, CHECK_NULL);
} else {
  new_obj_oop = Universe::heap()->obj_allocate(klass, size, CHECK_NULL);
}

HeapAccess<>::clone(obj(), new_obj_oop, size);         // 逐字段浅拷贝
```

- **分配**：`Universe::heap()->obj_allocate / array_allocate` 走当前 GC 的分配路径（TLAB 等），数组按长度分配。
- **拷贝**：`HeapAccess<>::clone` 是 GC 感知的逐字段拷贝——在 G1/ZGC 等带读屏障的 GC 里，源对象字段的读取要经过屏障（见 `barrierSet.hpp:312` 的 `clone_in_heap`），保证拷贝语义对 GC 正确。

## 六、第四步：finalizer 注册（904–911）

```cpp
Handle new_obj(THREAD, new_obj_oop);
// Caution: this involves a java upcall, so the clone should be
// "gc-robust" by this stage.
if (klass->has_finalizer()) {
  assert(obj->is_instance(), "should be instanceOop");
  new_obj_oop = InstanceKlass::register_finalizer(instanceOop(new_obj()), CHECK_NULL);
  new_obj = Handle(THREAD, new_obj_oop);
}
return JNIHandles::make_local(THREAD, new_obj());
```

- 如果克隆的类**有 finalizer**（重写了 `finalize` 且未禁用），新对象也要进 finalizer 队列（`register_finalizer`）。
- 905–906 行注释点出一个并发细节：`register_finalizer` 可能触发 Java upcall，所以此时克隆对象必须"GC 稳健"（已被 Handle 持有）。

## 七、验证实验

```java
public class C implements Cloneable {
    int[] arr = {1, 2, 3};
    public Object copy() throws Exception { return super.clone(); }
    public static void main(String[] a) throws Exception {
        C c = new C();
        C d = (C) c.copy();
        System.out.println(c == d);        // false：新对象
        System.out.println(c.arr == d.arr);// true：浅拷贝，数组引用照抄

        Object plain = new Object();
        try { plain.getClass().getMethod("clone").invoke(plain); }
        catch (Exception e) { System.out.println(e.getCause()); }  // CloneNotSupportedException
    }
}
```

```bash
D:\project\jdk\build\windows-x86_64-server-release\images\jdk\bin\java.exe C
```

## 附录：一句话索引

| 我想…… | 去哪里 |
|---|---|
| 看 clone 完整实现 | `jvm.cpp:859-914` |
| 看 Cloneable 标志怎么算出来的 | 搜 `is_cloneable` / `set_is_cloneable` |
| 看 GC 屏障拷贝 | `barrierSet.hpp:312` `clone_in_heap` |
| 看 finalizer 注册 | `InstanceKlass::register_finalizer` |
| 验证浅拷贝语义 | 上面的 `C` 示例 |
