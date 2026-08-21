# 05 · `static` — 类初始化 `<clinit>` 状态机

> **一句话**：`static` 不是关键字，是一整套"类级生命周期"协议——它在 class 文件里留下 `ACC_STATIC` 标志，驱动 VM 合成 `<clinit>` 方法，并由 `InstanceKlass::initialize_impl` 用一把"住在 Java mirror 里的锁"跑完整个初始化状态机。

---

## 快速概览

- **源码对象**：`InstanceKlass`（状态机 + 初始化锁）＋ `<clinit>` 合成方法（javac 侧）＋ `clinit_barrier`（解释器模板/C2 快速路径）
- **核心机制**：类初始化是**线程安全的单次执行**——多线程首次触达时只有一个执行者，其余阻塞等待，用 `_init_thread` 识别递归重入
- **状态机**：`allocated → loaded → linked → being_initialized → fully_initialized | initialization_error`（instanceKlass.hpp:195-202）
- **触发点**：`new`、`getstatic/putstatic`、`invokestatic`、反射、`Class.forName`、继承（父类先初始化）
- **JDK 28 新货**：① `strict static fields` 校验（`<clinit>` 结束后检查每个 strict static 字段是否被赋值，instanceKlass.cpp:1587-1615）；② 初始化锁就住在 **Java mirror** 里（`java_lang_Class::init_lock`，instanceKlass.cpp:910-918）；③ 初始化线程加 `NoPreemptMark` 防虚拟线程卸载（instanceKlass.cpp:1510）
- **与 04 的衔接**：`new` 模板里的 `clinit_barrier`（templateTable_x86.cpp:3756）就是 static 机制的渗透点——**new 一个类之前，它的 `<clinit>` 必须先跑完**

---

## 目录

1. [static 三兄弟：字段 / 方法 / 初始化块](#1-static-三兄弟字段--方法--初始化块)
2. [字节码视角：没有 static 字节码，只有 ACC_STATIC](#2-字节码视角没有-static-字节码只有-acc_static)
3. [类文件解析：ACC_STATIC 的旅途](#3-类文件解析acc_static-的旅途)
4. [触发条件：谁会让一个类开始初始化](#4-触发条件谁会让一个类开始初始化)
5. [状态机：ClassState 六态](#5-状态机classstate-六态)
6. [initialize_impl：十一小步的完整仪式](#6-initialize_impl十一小步的完整仪式)
7. [初始化锁：住在 Java mirror 里的秘密](#7-初始化锁住在-java-mirror-里的秘密)
8. [clinit_barrier：解释器层的两跳快速路径](#8-clinit_barrier解释器层的两跳快速路径)
9. [JDK 28 新发现：strict static fields 与 Valhalla 渗透](#9-jdk-28-新发现strict-static-fields-与-valhalla-渗透)
10. [验证实验](#10-验证实验)
11. [与系列其他篇的闭环](#11-与系列其他篇的闭环)

---

## 1. static 三兄弟：字段 / 方法 / 初始化块

`static` 在 Java 语法里修饰三类东西，但在 VM 眼里它们的行为差异巨大：

| 修饰目标 | javac 生成 | VM 侧机制 | 触发时机 |
|---|---|---|---|
| `static` 字段 | 普通字段 + `ACC_STATIC` 标志 | `putstatic/getstatic` 字节码 + clinit 屏障 | 访问字段（类先初始化） |
| `static` 方法 | 普通方法 + `ACC_STATIC` 标志 | `invokestatic` 字节码 + clinit 屏障 | 调用方法（类先初始化） |
| `static {}` 块 | **不生成独立方法**，代码并入 `<clinit>` | 无独立字节码 | 仅类初始化时执行一次 |

关键认知：**static 块和 static 字段初始化代码全部被 javac 合并进合成方法 `<clinit>`（`()V`）**，按源码顺序拼接。VM 侧 `class_initializer()` 用名字 + 签名精确找到它：

```cpp
// instanceKlass.cpp:2010-2017
Method* InstanceKlass::class_initializer() const {
  Method* clinit = find_method(
      vmSymbols::class_initializer_name(), vmSymbols::void_method_signature());  // "<clinit>" + "()V"
  if (clinit != nullptr && clinit->is_class_initializer()) {
    return clinit;
  }
  return nullptr;
}
```

`<clinit>` 符号定义在 `vmSymbols.hpp:397`：

```cpp
template(class_initializer_name, "<clinit>")  \
```

---

## 2. 字节码视角：没有 static 字节码，只有 ACC_STATIC

这是 static 跟 synchronized/volatile 最大的不同：**static 没有专属字节码**。

- `synchronized` → 有 `monitorenter/monitorexit`（bytecodes.hpp:238）
- `volatile` → 有 `ACC_VOLATILE` 标志（classFileParser.cpp:4626）
- `static` → 只有 `ACC_VOLATILE` 同款的 **`ACC_STATIC` 标志位**，加 `<clinit>` 合成方法

所有"static 语义"（类先初始化）都是 VM 在**解析/执行阶段**补的，靠的是 `clinit_barrier`（见 §8）——它在 `getstatic/putstatic/invokestatic/new` 四条字节码的模板里各插了一个快速路径检查。

```java
class Foo {
    static int x = 42;          // putstatic in <clinit>
    static { System.out.println("init"); }  // inlined into <clinit>
}
```

反编译视角：`Foo.class` 里 `x` 字段带 `ACC_STATIC`，`<clinit>` 方法里按序执行 `x = 42` 和 `println`。

---

## 3. 类文件解析：ACC_STATIC 的旅途

class 文件解析阶段（classFileParser.cpp），`ACC_STATIC` 决定字段和方法的解析方式：

```cpp
// classFileParser.cpp:2289-2291  —— 字段解析
flags = JVM_ACC_STATIC;                      // 接口字段隐式 static
} else if ((flags & JVM_ACC_STATIC) == JVM_ACC_STATIC) {
  flags &= JVM_ACC_STATIC | (_major_version <= JAVA_16_VERSION ? JVM_ACC_STRICT : 0);
```

```cpp
// classFileParser.cpp:2317  —— 方法解析：static 方法无 receiver，args_size=0
args_size = ((flags & JVM_ACC_STATIC) ? 0 : 1) + ...
```

顺带一提：JDK 16 起 `ACC_STRICT`（strictfp）从 static 方法上被剥离，`JAVA_16_VERSION` 之后 static 方法不再允许 strictfp 标志——这是"编译期型关键字"被 VM 清理的实证（见 01 篇的三类本质）。

---

## 4. 触发条件：谁会让一个类开始初始化

JLS 12.4.1 规定六类主动使用会触发初始化，落到 HotSpot 全是同一个入口 `InstanceKlass::initialize`：

| JLS 触发 | 字节码/API | clinit_barrier 位置 |
|---|---|---|
| `new` 创建实例 | `new` | templateTable_x86.cpp:3756 |
| 读/写 static 字段 | `getstatic/putstatic` | templateTable_x86.cpp:2376-2382 |
| 调 static 方法 | `invokestatic` | templateTable_x86.cpp:2327-2336 |
| 反射 | `Class.forName` / `getField` 等 | 走 JNI/reflection，无模板屏障 |
| 初始化子类 | 父类递归 | instanceKlass.cpp:1536-1540（Step 7） |
| 接口默认方法 | 超接口 | instanceKlass.cpp:1545-1547 |

注意：**`getfield/getstatic` 的字段读取本身不触发**——只有 `ACC_STATIC` 的访问才走 clinit 屏障。这就是为什么模板层只在 static 字节码上插屏障。

---

## 5. 状态机：ClassState 六态

`InstanceKlass` 用 1 字节的 `_init_state` 记录类生命周期（instanceKlass.hpp:195-202）：

```cpp
enum ClassState : u1 {
  allocated,                          // allocated (but not yet linked)
  loaded,                             // loaded and inserted in class hierarchy (but not linked yet)
  linked,                             // successfully linked/verified (but not initialized yet)
  being_initialized,                  // currently running class initializer
  fully_initialized,                  // initialized (successful final state)
  initialization_error                // error happened during initialization
};
```

前三个状态（allocated/loaded/linked）属于**加载-链接**阶段，初始化状态机只关心后三个：

```
linked ──(首次触达)──▶ being_initialized ──(<clinit> 成功)──▶ fully_initialized
                           │                                      ▲
                           │ (<clinit> 抛异常)                     │ 并发线程 wait 后醒来看到
                           ▼                                      │
                    initialization_error ──(再次访问)──▶ NoClassDefFoundError
```

状态读取/判断的封装（instanceKlass.hpp:614-620）：

```cpp
bool is_initialized() const        { return init_state() == fully_initialized; }
bool is_being_initialized() const  { return init_state() == being_initialized; }
bool is_in_error_state() const     { return init_state() == initialization_error; }
bool is_reentrant_initialization(Thread *thread) { return thread == _init_thread; }
ClassState init_state() const      { return AtomicAccess::load_acquire(&_init_state); }
```

配套字段（instanceKlass.hpp:274/286）：

```cpp
volatile ClassState _init_state;         // state of class
JavaThread* volatile _init_thread;       // Pointer to current thread doing initialization
```

`_init_thread` 是递归检测的关键——**同一线程重入自己的类初始化是合法的**（否则自引用就会死锁）。

---

## 6. initialize_impl：十一小步的完整仪式

入口包装（instanceKlass.cpp:961-966）：

```cpp
void InstanceKlass::initialize(TRAPS) {
  if (this->should_be_initialized()) {   // !is_initialized()
    initialize_impl(CHECK);
  }
}
```

`initialize_impl`（instanceKlass.cpp:1417-1651）内部按"JVM book page 47"的步骤组织，拆解如下：

### Step 1 · 抢初始化锁（1434-1436）

```cpp
Handle h_init_lock(THREAD, init_lock());
ObjectLocker ol(h_init_lock, CHECK_PREEMPTABLE);
```

锁就是对象自己的 mirror（见 §7）。`ObjectLocker` 是标准 monitor——**类初始化的并发控制本质就是 synchronized**。

### Step 2 · 等待执行者完成（1442-1451）

```cpp
while (is_being_initialized() && !is_reentrant_initialization(jt)) {
  ThreadWaitingForClassInit twcl(THREAD, this);   // JFR 事件
  ol.wait_uninterruptibly(CHECK_PREEMPTABLE);     // 阻塞直到执行者 notify_all
}
```

**别的线程正在初始化 → 我也抢到锁，但发现 being_initialized → 挂起等待。** 注意用 `wait_uninterruptibly`（可被中断的 wait 会从链接/符号解析点误抛 IE，见 6320309）。

### Step 3 · 递归重入 → 直接放行（1454-1462）

```cpp
if (is_being_initialized() && is_reentrant_initialization(jt)) {
  return;   // 自己正在初始化自己，合法重入
}
```

**这是 `_init_thread` 存在的全部意义**：T1 的 `<clinit>` 里触发了同一个类的初始化（自引用），此时 `thread == _init_thread`，直接返回，不会死锁。

### Step 4 · 已完成 → 直接放行（1465-1473）

```cpp
if (is_initialized()) { return; }   // 别人已经初始化完，我们醒来后看到
```

### Step 5 · 失败过 → 抛 NoClassDefFoundError（1476-1494）

```cpp
if (is_in_error_state()) {
  THROW_MSG_CAUSE(vmSymbols::java_lang_NoClassDefFoundError(),
                  ss.as_string(), cause);   // cause 是上次的异常
}
```

**初始化失败的类，之后所有访问都秒抛 NoClassDefFoundError**（原始异常作为 cause）。

### Step 6 · 当选执行者（1497-1505）

```cpp
set_init_state(being_initialized);
set_init_thread(jt);
```

**只有这一步在锁内写状态**，之后的 `<clinit>` 执行在锁外（避免持锁执行用户代码）。退出临界区前加 `NoPreemptMark`（1510）——虚拟线程时代，初始化线程不允许被卸载，否则重入检测的身份就乱了。

### Step 7 · 先初始化父类和超接口（1533-1563）

```cpp
if (!is_interface()) {
  Klass* super_klass = super();
  if (super_klass != nullptr && super_klass->should_be_initialized()) {
    super_klass->initialize(THREAD);          // 父类递归初始化
  }
  if (!HAS_PENDING_EXCEPTION && has_nonstatic_concrete_methods()) {
    initialize_super_interfaces(THREAD);      // 有默认方法的接口也要初始化
  }
}
```

**父类失败 → 子类也失败**：异常被记入 `initialization_error` 并向上抛（1550-1562）。

### Step 8 · 执行 `<clinit>`（1566-1616）

```cpp
call_class_initializer(THREAD);   // instanceKlass.cpp:1578
```

`call_class_initializer`（instanceKlass.cpp:2019-2059）：
- CDS 快路径：AOT 归档的类直接跑归档镜像初始化（`AOTClassInitializer::call_runtime_setup`，2030）
- 常规路径：`JavaCalls::call(&result, h_method, &args, CHECK)`（2057）——**普通 JVM 方法调用，无参数，返回 void**

Step 8 之后紧跟 JDK 28 的 **strict static fields 校验**（1587-1615，见 §9）。

### Step 9 · 成功收尾（1618-1623）

```cpp
set_initialization_state_and_notify(fully_initialized, CHECK);
```

### Step 10/11 · 失败收尾（1624-1649）

```cpp
add_initialization_error(THREAD, e);
set_initialization_state_and_notify(initialization_error, THREAD);
if (e->is_a(vmClasses::Error_klass())) {
  THROW_OOP(e());                      // Error 直接重抛
} else {
  THROW_ARG(vmSymbols::java_lang_ExceptionInInitializerError(), ...);  // 其余包一层
}
```

**`<clinit>` 抛异常 → 状态置 initialization_error → 抛 ExceptionInInitializerError**（原异常为 cause）。

---

## 7. 初始化锁：住在 Java mirror 里的秘密

反直觉点：**初始化锁不是 C++ 侧字段，而是 Java 堆里 mirror 对象上的一个隐藏字段**：

```cpp
// instanceKlass.cpp:910-918
oop InstanceKlass::init_lock() const {
  // return the init lock from the mirror
  oop lock = java_lang_Class::init_lock(java_mirror());
  OrderAccess::loadload();                     // 防重排
  return lock;
}
```

`java_lang_Class::init_lock(mirror)` 就是 `Class` 类里隐藏的 `initLock` 字段——**类初始化锁本质是"锁住这个类的 Class 对象"**。`fully_initialized` 后锁被清空（`fence_and_clear_init_lock`），mirror 可被 GC。

收尾函数（instanceKlass.cpp:1654-1667）：

```cpp
void InstanceKlass::set_initialization_state_and_notify(ClassState state, TRAPS) {
  Handle h_init_lock(THREAD, init_lock());
  if (h_init_lock() != nullptr) {
    ObjectLocker ol(h_init_lock, THREAD);
    set_init_thread(nullptr);          // 先清 _init_thread，再改状态
    set_init_state(state);
    fence_and_clear_init_lock();
    ol.notify_all(CHECK);              // 唤醒所有 Step 2 的等待者
  }
}
```

顺序敏感：**先清 `_init_thread` 再改 `_init_state`**，等待者醒来后读到新状态直接放行（Step 4）或抛错（Step 5）。

---

## 8. clinit_barrier：解释器层的两跳快速路径

模板层把"类已初始化"检查内联进热路径，宏实现（macroAssembler_x86.cpp:4835-4860）：

```cpp
void MacroAssembler::clinit_barrier(Register klass, Label* L_fast_path, Label* L_slow_path) {
  // Fast path check: class is fully initialized.
  cmpb(Address(klass, InstanceKlass::init_state_offset()), InstanceKlass::fully_initialized);
  jcc(Assembler::equal, *L_fast_path);                       // 跳 1：已初始化

  // Fast path check: current thread is initializer thread
  cmpptr(r15_thread, Address(klass, InstanceKlass::init_thread_offset()));
  ...                                                         // 跳 2：递归重入
  // 否则落 L_slow_path → 走字节码解析（resolve）
}
```

**两条快速路径都是 2 条指令**：① `init_state == fully_initialized` → 放行；② `r15_thread == _init_thread`（自己正在初始化，递归）→ 放行。都 miss 才走慢路径——解析（resolve）阶段会触发 `InstanceKlass::initialize`。

四个插入点（都是"拿到 field_holder/klass 之后马上查"）：

| 字节码 | 位置 | 检查的类 |
|---|---|---|
| `invokestatic` | templateTable_x86.cpp:2327-2336 | 方法所属类 |
| `getstatic/putstatic` | templateTable_x86.cpp:2376-2382 | field_holder |
| `new` | templateTable_x86.cpp:3756 | 实例化目标类 |

注意 x86 是 TSO，`init_state` 的 acquire 语义天然满足（4846 注释：*init_state needs acquire, but x86 is TSO, and so we are already good*）。

---

## 9. JDK 28 新发现：strict static fields 与 Valhalla 渗透

### 9.1 strict static fields（JEP 484 方向，instanceKlass.cpp:1587-1615）

`<clinit>` 执行完，VM 会**逐一检查每个 strict static 字段是否真的被赋值**：

```cpp
if (has_strict_static_fields() && !HAS_PENDING_EXCEPTION && !ReplayCompiles) {
  assert(fields_status() != nullptr, "");
  for (int index = 0; index < fields_status()->length(); index++) {
    if (fields_status()->adr_at(index)->is_strict_static_unset()) {
      // This strict static field has not been set by the class initializer.
      FieldInfo fi = field(index);
      bad_strict_static = fi.name(constants());
      ...
    }
  }
  if (bad_strict_static != nullptr) {
    throw_strict_static_exception(bad_strict_static, "is unset after initialization of", THREAD);
  }
}
```

机制：`fields_status` 是并行 1 字节/字段的位数组，解析期在 `ClassFileParser::post_process_parsed_stream` 建立（classFileParser.cpp:5917），`putstatic` 写 strict static 字段时清位（`notify_strict_static_access`，instanceKlass.cpp:1669）。`<clinit>` 结束后还有未赋值的 → 抛异常。

**为什么需要它**：strict static 字段（final static 的严格变体）要求"声明即赋值、构造器不可见"——VM 用位数组做**廉价的事后验证**，失败时报错而非猜测。这是继 `finalization` 之后又一个 JDK 28 级的语义收紧。

### 9.2 Valhalla 渗透

- `initialize_impl` Step 6 后：inline klass 若支持 nullable 布局，**预分配全零值**作为 null-reset 常量（1513-1531）
- 初始化线程加 `NoPreemptMark`（1510）：虚拟线程不被卸载，保 `_init_thread` 身份稳定

### 9.3 CDS 加速

归档类的 `<clinit>` 可能根本不用跑：AOT 镜像直接恢复（`AOTClassInitializer::call_runtime_setup`，2030），或枚举类走 `CDSEnumKlass::initialize_enum_klass`（2034）——启动性能从"跑一遍"变"抄一份"。

---

## 10. 验证实验

```bash
# 观察类初始化的并发等待日志
java -Xlog:class+init=debug -cp . FooDemo

# 期望输出（T2 等待 T1 的初始化）
# Thread "T2" waiting for initialization of Foo by thread "T1"
# Thread "T1" is initializing Foo
# Thread "T2" found Foo already initialized
```

测试代码：

```java
public class FooDemo {
    static class Foo {
        static { System.out.println("Foo <clinit> running on " + Thread.currentThread().getName()); }
        static int x = 42;
    }
    public static void main(String[] args) throws Exception {
        Thread t1 = new Thread(() -> { int y = Foo.x; }, "T1");
        Thread t2 = new Thread(() -> { int y = Foo.x; }, "T2");
        t1.start(); t2.start(); t1.join(); t2.join();
    }
}
```

再验证错误路径：

```java
static class Bar { static { throw new RuntimeException("boom"); } }
// 访问 Bar.x 第一次抛 ExceptionInInitializerError，第二次开始抛 NoClassDefFoundError
```

---

## 11. 与系列其他篇的闭环

| 关键字 | 衔接点 |
|---|---|
| `new`（04） | `new` 模板的 `clinit_barrier`（templateTable_x86.cpp:3756）——对象出生前类必须先初始化 |
| `synchronized`（02） | 初始化锁 = monitor（`ObjectLocker` + mirror 的 `initLock`），同一套锁体系 |
| `volatile`（03） | `_init_state` 的 acquire 语义（`AtomicAccess::load_acquire`，x86 上零成本） |
| `final`（后续） | strict static fields 是 final static 的严格化方向 |

**一句总结**：`static` = `ACC_STATIC`（解析期）＋ `<clinit>`（合成方法）＋ 六态状态机（`instanceKlass.hpp:195-202`）＋ mirror 锁（`instanceKlass.cpp:910`）＋ clinit_barrier 两跳快路径（`macroAssembler_x86.cpp:4835`）——把"类级生命周期"做成了一次线程安全、可重入、失败即冻结的协议。
