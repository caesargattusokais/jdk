# equals() / toString()：两个纯 Java 方法的语义地基

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Object 源码跟读 · 第 05 篇（[回到系列索引](README.md)）
> 主题：Object 里仅有的两个"有实现"的纯 Java 方法——为什么它们如此简单，又如此重要

---

## 快速概览

- **一句话结论**：`equals()` 和 `toString()` 是 Object 里**没有 native、没有注解**的两个普通 Java 方法。`equals` 就是 `this == obj`（引用相等），`toString` 就是 `getClass().getName() + "@" + hex(hashCode())`。它们存在的意义是给整个类体系**定义默认语义**，强迫每个子类去 override。
- **为什么读它们**：它们是"identity"（身份）概念在 Java 层的直接体现——与系列里 `hashCode`/`getClass` 呼应：**identity 对象的三件套 `==`、`hashCode`、`toString` 全部围绕对象身份**。
- **阅读顺序建议**：`Object.java:195` → `Object.java:311` → `Objects.java`（JDK 给的工具方法）。

### 核心文件索引

| 文件 | 关键行 | 内容 |
|---|---|---|
| `src/java.base/share/classes/java/lang/Object.java` | 195–197 | `equals` 实现（`this == obj`） |
| `src/java.base/share/classes/java/lang/Object.java` | 311–313 | `toString` 实现 |
| `src/java.base/share/classes/java/util/Objects.java` | 62 | `Objects.equals`（null 安全） |
| `src/java.base/share/classes/java/util/Objects.java` | 185 | `Objects.toIdentityString` |

---

## 一、equals()：最"严格"的等价关系

`Object.java:195-197`：

```java
public boolean equals(Object obj) {
    return (this == obj);
}
```

就一行。但它前面挂着 JDK 里**字数最多的 Javadoc**之一（134–194 行），定义了等价关系的五条契约：

1. **自反**：`x.equals(x)` 为 true
2. **对称**：`x.equals(y)` ⇔ `y.equals(x)`
3. **传递**：`x.equals(y)` 且 `y.equals(z)` ⇒ `x.equals(z)`
4. **一致**：比较信息不变，多次调用结果一致
5. **非空**：`x.equals(null)` 为 false

### JDK 28 的新措辞（168–179 行 @implSpec）

> returns `true` if and only if `x` and `y` refer to the same identity object or **indistinguishable value objects** (`x == y` has the value true)

注意这是 Valhalla 时代的措辞：**value object 的 `==` 也可能是 true**（不可区分），所以 equals 的定义从"同一对象"放宽到"`==` 为 true"。这是 JDK 28 相对旧文档的实质变化。

### 为什么 Object 的 equals 必须是 `==`

因为 Object 无法知道子类"相等"的业务含义——它只能提供**最严苛的默认**（每个等价类只有单一元素，178 行原话），把"放宽"的责任交给子类 override。这就是为什么 HashMap 的 key、Set 的元素都要 override equals + hashCode（180–184 行 apiNote 强调了两者的联动）。

### 配套工具：Objects.equals（Objects.java:62）

```java
public static boolean equals(Object a, Object b) {
    return (a == b) || (a != null && a.equals(b));
}
```

null 安全的包装，读它是为了记住：**写业务代码时永远用 `Objects.equals`，别手写 null 判断**。

## 二、toString()：类名@哈希

`Object.java:311-313`：

```java
public String toString() {
    return getClass().getName() + "@" + Integer.toHexString(hashCode());
}
```

三个细节：

1. **用的是 `getClass().getName()` 而不是 `this.getClass().getName()`**——`getClass` 是 final native，无覆盖风险，省略 this 只是风格。关键：`getName()` 返回的是**运行时类的全限定名**（如 `java.lang.Integer`）。
2. **`Integer.toHexString(hashCode())`**：无符号十六进制，不补零。所以默认 toString 长这样：`java.lang.Object@2f0e140b`。
3. **不保证稳定**（293–294 行）：hash 每次 JVM 运行可能不同（`get_next_hash` 用线程本地随机状态），所以 toString 输出"not necessarily stable over time or across JVM invocations"——**别解析 toString 做逻辑**。

### 配套工具：Objects.toIdentityString（Objects.java:185）

JDK 19 引入，返回**忽略 override 的身份字符串**——即使子类重写了 toString/hashCode，也能拿到"Object 风格的"原始输出：

```java
public static String toIdentityString(Object o) {
    return o.getClass().getName() + "@" + Integer.toHexString(System.identityHashCode(o));
}
```

注意它内部用 `System.identityHashCode(o)`——绕过重写的 `hashCode()`，直接调 `Object.hashCode` 的 native 语义（即 [03](03-hashCode.md) 里那套 `FastHashCode`）。

## 三、把三篇串起来：identity 三件套

| 视角 | `==` / `equals` | `hashCode()` | `toString()` |
|---|---|---|---|
| Java 层语义 | 引用相等 | 身份哈希 | 类名@哈希 |
| 底层实现 | Object.java:195 | `FastHashCode`（synchronizer.cpp:678） | 纯 Java 组合 |
| 绕过 override | `System.identityHashCode` | `System.identityHashCode` | `Objects.toIdentityString` |
| 相关文档 | 本篇 | [03](03-hashCode.md) | 本篇 |

`System.identityHashCode` 是 JDK 提供的"绕过 override"通道，它的 native 实现走的就是 `JVM_IHashCode`——在 [03](03-hashCode.md) 的链路上。

## 四、验证实验

```java
public class E {
    @Override public String toString() { return "myToString"; }
    @Override public int hashCode() { return 42; }
    public static void main(String[] a) {
        E e = new E();
        System.out.println(e);                                // myToString（被覆盖）
        System.out.println(java.util.Objects.toIdentityString(e)); // 类名@原始hash
        System.out.println(java.util.Objects.equals(null, e));     // false（null 安全）
    }
}
```

```bash
D:\project\jdk\build\windows-x86_64-server-release\images\jdk\bin\java.exe E
```

## 附录：一句话索引

| 我想…… | 去哪里 |
|---|---|
| 看 equals 契约全文 | `Object.java:134-194` |
| 看 toString 组合逻辑 | `Object.java:311-313` |
| null 安全比较 | `Objects.java:62` |
| 绕过 override 拿身份字符串 | `Objects.java:185` |
| identity hash 的底层 | [03-hashCode.md](03-hashCode.md) |
