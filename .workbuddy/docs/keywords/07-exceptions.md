# try / catch / finally / throw / throws：异常处理全家桶

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Java 关键字源码跟读 · 第 07 篇（[回到系列索引](README.md)）
> 前置：[06 instanceof 类型检查](06-instanceof.md)

---

## 快速概览

- **一句话结论**：异常处理是"**编译期布局 + 运行期查表**"的组合——javac 把 `try/catch/finally` 摊平成一张**异常表**（Exception Table，`constMethod.hpp:111` 的 `ExceptionTableElement` 四元组），`throw` 变成 `athrow` 字节码（0xbf）；运行期抛异常后，解释器/编译器在**当前方法内查表找 handler**（`Method::fast_exception_handler_bci_for`，`method.cpp:275`），找不到就**解栈上抛**给调用者。
- **五个关键字三个落点**：
  1. **`try/catch/finally`** → 异常表（数据躺在 `constMethod` 内联表里）；
  2. **`throw`** → `athrow` 字节码（模板 `templateTable_x86.cpp:4022`）；
  3. **`throws`** → `Exceptions` 属性（方法级受检异常声明，`classFileParser.cpp:1862` 解析）。
- **核心算法**（本篇主线）：`fast_exception_handler_bci_for` 顺序扫异常表——① 区间覆盖 `beg ≤ bci < end`；② `catch_type_index == 0` 是 catch-all（`catch(Exception)`/finally）；③ 否则 **`ex_klass->is_subtype_of(k)`**——06 篇的 instanceof 算法在这里被复用！
- **finally 没有字节码**：javac 把 finally 代码**复制**到 try 块的所有退出路径（正常 + 异常），异常路径用异常表里 `catch_type_index=0` 的记录兜底。class 文件里 finally 代码出现**多次**。
- **JDK 28 观察**：解释器路径上 `exception_handler_for_exception`（`interpreterRuntime.cpp:507`）负责"找到 handler 或解栈"，返回 continuation address；无 handler 时走 `remove_activation_entry` 把异常抛给调用帧。

---

## 目录

1. [全景：五个关键字三个落点](#一全景五个关键字三个落点)
2. [异常表数据结构：ExceptionTableElement](#二异常表数据结构exceptiontableelement)
3. [athrow：throw 的字节码与解释器模板](#三athrowthrow-的字节码与解释器模板)
4. [handler 查找算法：fast_exception_handler_bci_for](#四handler-查找算法fast_exception_handler_bci_for)
5. [解释器包装与解栈：exception_handler_for_exception](#五解释器包装与解栈exception_handler_for_exception)
6. [finally 的复制语义（编译期真相）](#六finally-的复制语义编译期真相)
7. [throws 与 Exceptions 属性](#七throws-与-exceptions-属性)
8. [JDK 28 vs 教科书差异](#八jdk-28-vs-教科书差异)
9. [验证实验](#九验证实验)
10. [与系列主线闭环](#十与系列主线闭环)

---

## 一、全景：五个关键字三个落点

| 关键字 | 编译期产物 | 运行期机制 | 源码锚点 |
|---|---|---|---|
| `try` | 异常表区间起点 | 无专门指令，仅查表 | `ExceptionTableElement`（constMethod.hpp:111） |
| `catch` | 异常表一条记录（含 handler_pc） | 查表命中 → 跳 handler | `method.cpp:275` 查找算法 |
| `finally` | **代码复制** + catch-all 异常表记录 | 查表兜底（`catch_type_index=0`） | javac 编译期（§6） |
| `throw` | `athrow` 0xbf | null 检查 → `throw_exception_entry` | `bytecodes.hpp:235`、`templateTable_x86.cpp:4022` |
| `throws` | `Exceptions` 属性 | **纯编译期校验**（javac 检查受检异常），运行期无动作 | `classFileParser.cpp:1862/2545` |

> 关键认知：**JVM 规范没有"异常处理指令"**——try/catch/finally 全是数据（异常表）+ 普通跳转。`athrow` 的唯一职责是"把对象抛出去"，之后交给查表逻辑。

## 二、异常表数据结构：ExceptionTableElement

```cpp
// Utility class describing elements in exception table
class ExceptionTableElement {
 public:
  u2 start_pc;        // try 块起始 bci（含）
  u2 end_pc;          // try 块结束 bci（不含）
  u2 handler_pc;      // handler 起始 bci
  u2 catch_type_index;// 捕获类型常量池索引；0 = catch-all（finally/Exception）
};
```

- 定义：`constMethod.hpp:111-117`。**四个 u2**，8 字节/条（JDK 28 仍是短格式；`handlers_p` 长条目格式在本仓库未启用，见 §8）。
- 存储位置：`constMethod` 的**内联表**（`INLINE_TABLES_DO` 宏登记，`constMethod.hpp:130` 的 `exception_table_length`），紧跟在方法字节码后面，**属于方法的一部分**，随 `ConstMethod` 一次性分配。
- 访问入口：`Method::exception_table_start()`（`method.hpp:293-294`）；`ExceptionTable` 助手类（`method.hpp:998`）封装成 `start_pc(idx)/end_pc(idx)/handler_pc(idx)/catch_type_index(idx)` 四件套。

> 对比 javap 输出：`Exception table: from to target type 0 4 12 Class java/lang/Exception`——四列正好对应四个 u2 字段。

## 三、athrow：throw 的字节码与解释器模板

字节码定义（`bytecodes.hpp:235`）：

```cpp
_athrow = 191, // 0xbf
```

解释器模板只有 4 行（`templateTable_x86.cpp:4022-4026`）：

```cpp
void TemplateTable::athrow() {
  transition(atos, vtos);      // 栈顶引用 → 无返回值
  __ null_check(rax);          // throw null → NPE（JLS：先抛 NPE）
  __ jump(RuntimeAddress(Interpreter::throw_exception_entry()));
}
```

三个要点：
1. **`throw null` 的语义**：javac 把 `throw null` 编译成 `aconst_null; athrow`，模板里 `null_check` 把 null 转成 **NullPointerException**——这解释了 JLS 的"throw null 抛 NPE"是怎么实现的；
2. **栈型 atos→vtos**：对象被"消费"（进异常处理机制），方法执行流被打断；
3. **跳 `throw_exception_entry`**：这是解释器预先生成的一段**公用例程**，负责设置异常 oop、调用 `InterpreterRuntime::exception_handler_for_exception` 查表（§5）。

## 四、handler 查找算法：fast_exception_handler_bci_for

核心算法在 `Method::fast_exception_handler_bci_for`（`method.cpp:275`）。**顺序扫描**异常表（不是二分！因为区间可能重叠，第一个命中者胜）：

```cpp
int Method::fast_exception_handler_bci_for(const methodHandle& mh,
                                           Klass* ex_klass, int throw_bci, TRAPS) {
  ExceptionTable table(mh());
  int length = table.length();
  constantPoolHandle pool(THREAD, mh->constants());
  for (int i = 0; i < length; i ++) {
    ExceptionTable table(mh());        // GC 后重新获取
    int beg_bci = table.start_pc(i);
    int end_bci = table.end_pc(i);
    if (beg_bci <= throw_bci && throw_bci < end_bci) {   // ① 区间覆盖
      int handler_bci = table.handler_pc(i);
      int klass_index = table.catch_type_index(i);
      if (klass_index == 0) {          // ② catch-all（finally / catch(Exception)）
        return handler_bci;            //   直接命中，不比较类型
      } else if (ex_klass == nullptr) {
        return handler_bci;            // 异常对象为 null 的边界情形
      } else {
        Klass* k = pool->klass_at(klass_index, THREAD);  // 解析捕获类型
        if (HAS_PENDING_EXCEPTION) return handler_bci;   // 解析失败也进 handler
        if (ex_klass->is_subtype_of(k)) {                // ③ 子类型判定！
          return handler_bci;                            //    instanceof 算法复用
        }
      }
    }
  }
  return -1;                           // 无 handler → 解栈上抛
}
```

算法三要素：

| 步骤 | 条件 | 说明 |
|---|---|---|
| **① 区间覆盖**（296） | `beg_bci ≤ throw_bci < end_bci` | try 块范围是 `[start, end)`，半开区间 |
| **② catch-all 短路**（302） | `klass_index == 0` | `catch(Exception)` 与 finally 都是 0，**免类型比较**直接命中 |
| **③ 子类型判定**（336） | `ex_klass->is_subtype_of(k)` | 就是 06 篇的算法！`catch (IOException)` 能接住 `FileNotFoundException` 的原因 |

> 教科书差异：教科书说"catch 按声明顺序匹配"，本质是**异常表顺序 = javac 生成顺序**，运行期就是顺序扫描 + 第一个命中者。且 `catch(IOException)` 匹配子类用的正是 instanceof 的 `is_subtype_of`——两个关键字在此交汇。

## 五、解释器包装与解栈：exception_handler_for_exception

`InterpreterRuntime::exception_handler_for_exception`（`interpreterRuntime.cpp:507`）是 athrow 公用例程调用的 VM 入口，职责是**找到 handler 或把异常交给上层帧**：

```
do {
  handler_bci = Method::fast_exception_handler_bci_for(h_method, klass, current_bci, THREAD);
  if (HAS_PENDING_EXCEPTION) {       // 找 handler 途中又抛了新异常
    h_exception = Handle(THREAD, PENDING_EXCEPTION);  // 换异常重查（bug 4307310）
    CLEAR_PENDING_EXCEPTION;
    if (handler_bci >= 0) { current_bci = handler_bci; should_repeat = true; }
  }
} while (should_repeat);

if (handler_bci < 0 || !reguard_stack(...)) {
  continuation = Interpreter::remove_activation_entry();   // ← 本方法无 handler：解栈上抛
} else {
  handler_pc = h_method->code_base() + handler_bci;        // ← 有 handler：改 bcp
  set_bcp_and_mdp(handler_pc, current);
  continuation = Interpreter::dispatch_table(vtos)[*handler_pc];  // 跳到 handler 第一条
}
```

关键点：
- **`handler_bci < 0` → `remove_activation_entry`**：把当前帧拆掉，异常对象留在 TLS（`vm_result`），控制权回到**调用者**——调用者要么自己有 handler（重新查表），要么继续解栈，一路抛到 main → 打印堆栈；
- **`handler_bci >= 0` → 改 bcp 继续**：解释器直接跳到 handler 第一条指令，栈上保留 try 块里的局部变量（handler 通过局部变量表访问）；
- JVMTI 钩子（596-598）：`post_exception_throw` 让调试器能拦到每一次抛异常。

## 六、finally 的复制语义（编译期真相）

**JVM 里没有 finally 指令**——这是 javac 的编译期魔术。看一段代码的字节码就明白了：

```java
try { risky(); } finally { cleanup(); }
```

javac 生成（示意，`javap -c` 可验证）：

```
 0: invokestatic risky        // try 块
 3: invokestatic cleanup      // ← 正常出口：直接复制 finally
 6: goto 14
 9: astore_1                  // 异常对象入槽
10: invokestatic cleanup      // ← 异常出口：再次复制 finally
13: aload_1                   // 重新抛
14: return
Exception table:
 from  to  target type
    0   3     9    any        // ← catch-all：type=0
```

三个工程后果：
1. **代码膨胀**：finally 块复制到**每个退出点**（正常 return、每个异常出口）。finally 里有 try-finally 会指数级复制（经典面试陷阱的根源）；
2. **catch-all 兜底**：异常出口通过 `type=any`（`catch_type_index=0`）的记录进 finally；finally 跑完后 `aload_1 + athrow` **原样重抛**——所以 finally 里 return 会吞掉异常（`aload_1` 被跳过）；
3. **`catch` 里也有复制**：JDK 7+ 的 try-with-resources 更是把 close 逻辑复制进每个出口。

> 验证：任意带 finally 的类 `javap -c -v`，数一数 finally 代码出现了几次。

## 七、throws 与 Exceptions 属性

`throws` 关键字编译成方法的 **`Exceptions` 属性**（区别于异常表 `Exception_table`！容易混淆）：

- 解析入口：`ClassFileParser::parse_checked_exceptions`（`classFileParser.cpp:1862`），在属性循环里于 `classFileParser.cpp:2545`（"Parse Exceptions attribute"）被调用；
- 数据格式：`u2 number_of_exceptions + u2[] exception_index_table`——一串常量池 Class 索引；
- **运行期零作用**：VM 不查它、不校验它。`throws` 的全部意义是**编译期**：javac 在方法调用处检查"受检异常是否被捕获或声明"（`com.sun.tools.javac.comp.Check`），class 文件里它只是留给反射/工具看的一份声明。

> 对比：`throws IOException` 是"声明可能抛出"（编译期约束）；`catch (IOException e)` 是"真的接住"（运行期查表）。前者进 `Exceptions` 属性，后者进异常表——两个完全不同的属性。

## 八、JDK 28 vs 教科书差异

| 教科书说法 | JDK 28 真相 | 证据 |
|---|---|---|
| 异常处理是"指令级"机制 | **纯数据 + 查表**，只有 `athrow` 一条指令 | `bytecodes.hpp:235` |
| catch 按声明顺序匹配 | 异常表顺序扫描 + **第一个命中者**（`beg ≤ bci < end`） | `method.cpp:287-296` |
| `catch(Exception)` 是普通 catch | 它是 **catch-all**（`catch_type_index=0`），免类型比较 | `method.cpp:302-308` |
| catch 匹配是"类相等" | 是 **`is_subtype_of` 子类型判定**（06 篇算法） | `method.cpp:336` |
| finally 是"特殊代码块" | finally **没有字节码**，是 javac 复制出来的代码 + catch-all 异常表记录 | §6 |
| 异常表是长格式（handlers_p） | JDK 28 本仓库仍用 **4×u2 短格式**（`ExceptionTableElement`） | `constMethod.hpp:111-117` |
| throw null 直接抛 null | 模板先 `null_check` → **NPE** | `templateTable_x86.cpp:4024` |
| 抛异常后要"解栈查找" | 先在**当前方法查表**，无 handler 才 `remove_activation_entry` 上抛 | `interpreterRuntime.cpp:602-610` |

## 九、验证实验

```java
// ExDemo.java
public class ExDemo {
    static void risky() throws java.io.IOException { throw new java.io.FileNotFoundException("f"); }
    public static void main(String[] a) {
        try { risky(); }
        catch (java.io.IOException e) { System.out.println("IO: " + e); }
        finally { System.out.println("finally"); }
    }
}
```

1. **看布局**：`javap -c -v ExDemo` → 数 finally 代码出现次数（正常出口 + 异常出口 = 2 次）；看 `Exception table` 的 `type` 列：IO 的记录是类名，finally 的记录是 `any`；
2. **看 throws**：`javap -v` 方法属性区有 `Exceptions: throws java.io.IOException`——与异常表区分开；
3. **看子类型匹配**：把 `risky()` 改成抛 `FileNotFoundException`（IOException 的子类），catch(IOException) 仍能接住——这就是 §4 的 `is_subtype_of`（可用 06 篇的 `-XX:+PrintAssembly` 思路验证）；
4. **看解栈**：`java -XX:+TraceExceptions ExDemo` 观察 VM 逐帧查表、逐帧上抛的日志；
5. **finally 吞异常**：`finally { return; }` 后 catch 收不到异常——验证 §6 的 `aload_1` 被跳过。

## 十、与系列主线闭环

- **instanceof（06）**：catch 类型匹配 `ex_klass->is_subtype_of(k)`（method.cpp:336）直接复用 06 篇的 Klass 双通道算法——两个关键字共用一个引擎；
- **static（05）**：类初始化失败会抛 `ExceptionInInitializerError`，之后访问走 `NoClassDefFoundError`——异常机制是 clinit 错误传播的通道；
- **synchronized（02）**：monitorexit 由 javac 生成在 finally 位置（异常出口也会执行），靠的正是本篇的 catch-all + finally 复制语义——**锁的释放是异常安全的**；
- **下一站（08）**：final 三面孔——ConstantValue 属性、final 方法不进 vtable、final 字段 JMM freeze 语义。

---

> 下一篇：[08 final 三面孔](08-final.md) —— ConstantValue / vtable / JMM freeze
