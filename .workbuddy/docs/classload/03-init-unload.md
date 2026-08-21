# 类加载站③：初始化与卸载——`<clinit>` 的触发、并发与回收

> 站②讲完链接：类已「接线」（`is_linked()` = true），可以上岗了。但「上岗」前还有最后一道仪式——**初始化（Initialization）**：真正执行 `<clinit>`，把静态字段从默认值赋成程序员写的值。
> 这一站讲四件事：**① 什么时候触发 `<clinit>`；② 并发下怎么保证只初始化一次；③ 初始化失败怎么处理；④ 类什么时候被卸载、怎么回收。**
> 本文锚点全部来自 JDK 28 mainline（`src/hotspot/share/`），行号可对照源码逐行核对。

---

## 快速概览

- **一句话**：初始化 = 执行 `<clinit>`（静态字段真正赋值）；HotSpot 用 `init_lock` + 状态机（uninitialized → being_initialized → fully_initialized / initialization_error）保证**并发下只初始化一次**、**递归初始化安全**、**失败后其余线程拿到同一个错误**；卸载由 GC 触发，跟着 `ClassLoaderData` 一起回收。
- **白话比喻**：站①招人、站②入职培训（链接），站③是「**上岗宣誓**」——`<clinit>` 就是誓词，把静态字段从默认装备换成真家伙。宣誓有严格纪律：**一次只能一个人上台**（init_lock），别人等着（wait）；**誓词念一半自己又上台**（递归初始化）直接放行；**念砸了**（异常）全场散会，后面的人来问都说「这人不行」（NoClassDefFoundError + 原因）。
- **核心结论**：初始化不是「加载时自动完成」——它只在**主动使用**（new / 静态访问 / 反射）时才触发；HotSpot 把「触发」撒在解释器/JIT 的各个入口（`_new`、静态字段读写），把「执行」收拢在 `initialize_impl`（instanceKlass.cpp:1417）一把锁里。

**关键源码入口**

| 动作 | 函数 | 位置 |
|---|---|---|
| 初始化入口 | `InstanceKlass::initialize` | instanceKlass.cpp:961 |
| 初始化实现（核心） | `InstanceKlass::initialize_impl` | instanceKlass.cpp:1417 |
| new 指令触发 | `InterpreterRuntime::_new` | interpreterRuntime.cpp:223（→:231 触发初始化） |
| 静态字段访问触发 | `uninitialized_static` 检查 | interpreterRuntime.cpp:741 |
| 执行 `<clinit>` | `call_class_initializer` | instanceKlass.cpp:2019 |
| 查找 `<clinit>` | `class_initializer` | instanceKlass.cpp:2010 |
| 状态机判断 | `is_initialized` / `is_being_initialized` / `is_in_error_state` / `is_reentrant_initialization` | instanceKlass.hpp:614-618 |
| 卸载（GC 入口） | `ClassLoaderDataGraph::do_unloading` | classLoaderDataGraph.cpp:410 |
| 卸载实现 | `ClassLoaderData::unload` | classLoaderData.cpp:604 |

---

## TOC

1. [什么时候触发 `<clinit>`：主动使用清单](#1-什么时候触发-clinit主动使用清单)
2. [关卡① 触发入口：`_new` 与静态访问的初始化屏障](#2-关卡①-触发入口_new-与静态访问的初始化屏障)
3. [关卡② 状态机与并发：一次只初始化一次](#3-关卡②-状态机与并发一次只初始化一次)
4. [关卡③ 执行 `<clinit>`：父类先行 + 誓词上台](#4-关卡③-执行-clinit父类先行--誓词上台)
5. [关卡④ 失败处理与卸载：错误表与 GC 回收](#5-关卡④-失败处理与卸载错误表与-gc-回收)
6. [JLS 12.4 vs HotSpot 实现：主动使用对照](#6-jls-124-vs-hotspot-实现主动使用对照)
7. [与站①②衔接：加载 → 链接 → 初始化 → 卸载](#7-与站①②衔接加载--链接--初始化--卸载)
8. [行号速查](#8-行号速查)

---

## 1. 什么时候触发 `<clinit>`：主动使用清单

JLS（Java 语言规范）12.4.1 规定，类的初始化发生在**首次主动使用**时，主动使用包括：

- `new`（创建实例）→ `new` 字节码
- 访问静态字段（`getstatic` / `putstatic`）→ 但编译期常量（`static final` 常量池里直接内联的）不触发
- 调用静态方法（`invokestatic`）
- 反射：`Class.forName`、`Class.newInstance`、`Method.invoke` 等
- 初始化子类（先初始化父类）
- 程序入口类（main 所在类）

**反例（不触发初始化）**：通过子类访问父类的静态字段（只初始化父类）、数组创建（`new Dog[10]` 只初始化数组类型）、访问编译期常量。

> **白话**：`<clinit>` 是「懒」的——没人真的用它，它就永远不宣誓。这也是为什么 `main` 类、`new` 目标类、静态访问目标类必须做初始化屏障（见关卡①）。

---

## 2. 关卡① 触发入口：`_new` 与静态访问的初始化屏障

解释器执行字节码时，凡涉及「主动使用」的指令都带一道**初始化屏障**——先检查类是否已初始化，没初始化就先初始化。

### 2.1 `new` 指令（interpreterRuntime.cpp:223）

```cpp
// interpreterRuntime.cpp:223
JRT_ENTRY(void, InterpreterRuntime::_new(JavaThread* current, ConstantPool* pool, int index))
  Klass* k = pool->klass_at(index, CHECK);              // :224 解析类
  InstanceKlass* klass = InstanceKlass::cast(k);
  klass->check_valid_for_instantiation(true, CHECK);    // :228 抽象类拦截
  klass->initialize_preemptable(CHECK_AND_CLEAR_PREEMPTED); // :231 初始化屏障！
  oop obj = klass->allocate_instance(CHECK);            // :233 分配对象
JRT_END
```

`new` 的执行顺序：**解析类（:224）→ 拦截抽象类（:228）→ 初始化屏障（:231）→ 分配对象（:233）**。对象分配必须在初始化完成后——否则可能拿到静态字段还是默认值的半成品。

### 2.2 静态字段访问（interpreterRuntime.cpp:741）

```cpp
// interpreterRuntime.cpp:741（静态字段解析路径）
bool uninitialized_static = is_static && !klass->is_initialized();
```

访问静态字段时发现类未初始化 → 先走 `initialize` 再取字段。静态方法调用（`invokestatic`）同理。

> **白话**：初始化屏障 = 门卫。「想进场（new / 摸静态字段）？先确认台上的人宣誓完没有，没有就先宣誓。」

---

## 3. 关卡② 状态机与并发：一次只初始化一次

`initialize_impl`（instanceKlass.cpp:1417）是整个初始化的**单点执行者**——所有触发路径最终都汇聚到这里。它用 `init_lock`（instanceKlass.cpp:910）保护一段**状态机**逻辑。

### 3.1 状态机四态（instanceKlass.hpp:614-618）

| 状态 | 判断方法 | 含义 |
|---|---|---|
| `uninitialized` | 默认 | 还没开始初始化 |
| `being_initialized` | `is_being_initialized`（:616） | 正在初始化（有线程上台了） |
| `fully_initialized` | `is_initialized`（:614） | 初始化完成 |
| `initialization_error` | `is_in_error_state`（:617） | 初始化失败（誓词念砸了） |

### 3.2 状态机流转（instanceKlass.cpp:1434-1505）

```cpp
// instanceKlass.cpp:1434-1505（Step 1-6）
ObjectLocker ol(h_init_lock, CHECK_PREEMPTABLE);   // Step 1: 拿 init_lock  :1436
while (is_being_initialized() && !is_reentrant_initialization(jt)) {  // Step 2: 别人在初始化 → 等
  ol.wait_uninterruptibly(CHECK_PREEMPTABLE);      //                    :1450
}
if (is_being_initialized() && is_reentrant_initialization(jt)) {  // Step 3: 自己递归 → 放行
  return;                                           //                    :1461
}
if (is_initialized()) { return; }                  // Step 4: 已完成 → 直接回 :1472
if (is_in_error_state()) {                          // Step 5: 失败过 → 抛同一个错
  Handle cause(THREAD, get_initialization_error(THREAD));  //        :1485
  THROW_MSG_CAUSE(vmSymbols::java_lang_NoClassDefFoundError(), ..., cause); // :1492
} else {
  set_init_state(being_initialized);               // Step 6: 上台！:1498
  set_init_thread(jt);                             //          :1499
}
```

**并发三原则**：

1. **互斥**：`ObjectLocker`（:1436）——同一时刻只有一个线程进入状态机核心。
2. **等待**：其他线程发现 `being_initialized`（:1442）就 `wait_uninterruptibly`（:1450）——等初始化线程完成后的 `notify_all`（见 :1661）。
3. **递归安全**：`is_reentrant_initialization`（instanceKlass.hpp:618，`thread == _init_thread`）——**同一个线程**再次进入（比如 `<clinit>` 里又 `new` 自己）直接放行（:1461），不死锁。

### 3.3 可重入场景

`<clinit>` 内部 `new 自己`（`static Foo f = new Foo()`）——此时 `_init_thread` 就是当前线程 → `is_reentrant_initialization` = true → Step 3 直接 return，不等待不报错。

> **白话**：台上只有一个人（being_initialized），其他人排队（wait），排队的被叫醒后发现「完事了」（fully_initialized）就散场，「搞砸了」（error）就领同一个「这人不行」的结论回去。

---

## 4. 关卡③ 执行 `<clinit>`：父类先行 + 誓词上台

### 4.1 Step 7：先初始化父类（instanceKlass.cpp:1536-1547）

```cpp
// instanceKlass.cpp:1536-1547
if (!is_interface()) {
  Klass* super_klass = super();
  if (super_klass != nullptr && super_klass->should_be_initialized()) {
    super_klass->initialize(THREAD);       // :1539 先初始化父类（递归）
  }
  if (!HAS_PENDING_EXCEPTION && has_nonstatic_concrete_methods()) {
    initialize_super_interfaces(THREAD);   // :1546 再初始化含 default 方法的接口
  }
}
```

**父类先行**：JLS 规定初始化 C 前必须先初始化 C 的父类——子类静态字段可能依赖父类的静态字段。父类失败（:1550-1562）→ 记错误 + 置 `initialization_error` + 抛。

### 4.2 Step 8：调用 `<clinit>`（instanceKlass.cpp:1569-1585 → :2019）

```cpp
// instanceKlass.cpp:1569-1585
if (class_initializer() != nullptr) {
  ...
  call_class_initializer(THREAD);          // :1578 执行 <clinit>
} else { ... call_class_initializer(THREAD); }
```

`class_initializer`（:2010）从方法表里找 `<clinit>()V`（`find_method` :2011，`is_class_initializer` :2013 确认静态无参）；`call_class_initializer`（:2019）核心就一行：

```cpp
// instanceKlass.cpp:2057
JavaCalls::call(&result, h_method, &args, CHECK);  // 静态调用，无参数
```

`JavaCalls::call` 是 HotSpot 内部执行 Java 方法的统一入口——`<clinit>` 以普通静态方法的形式被调起（解释器或 JIT 入口，取决于链接期 `link_method` 的决定）。

### 4.3 Step 9：成功与失败（instanceKlass.cpp:1618-1649）

```cpp
// instanceKlass.cpp:1618-1649
if (!HAS_PENDING_EXCEPTION) {
  set_initialization_state_and_notify(fully_initialized, CHECK);  // :1620 成功！
  ...
} else {
  Handle e(THREAD, PENDING_EXCEPTION);
  ...
  add_initialization_error(THREAD, e);                            // :1633 记录错误
  set_initialization_state_and_notify(initialization_error, THREAD); // :1634 置 error
  ...
  THROW_ARG(vmSymbols::java_lang_ExceptionInInitializerError(), ...); // :1645 包一层抛
}
```

**成功**：置 `fully_initialized` + `notify_all` 唤醒所有等待线程（:1654-1662，先清 `_init_thread` :1658）。
**失败**：`<clinit>` 抛出的原始异常（比如 `NullPointerException`）被 `add_initialization_error`（:1344）记入**初始化错误表**（`_initialization_error_table`，:1341），状态置 `initialization_error`，然后**包一层 `ExceptionInInitializerError`** 抛给当前线程（:1645）——原始异常作为 cause。

> **白话**：先让爸妈宣誓（父类初始化），自己再上台念誓词（`<clinit>`）。念完拍板「成了」（fully_initialized），念砸了记黑账（错误表）并让后面的人都知道（NoClassDefFoundError 带原始原因）。

---

## 5. 关卡④ 失败处理与卸载：错误表与 GC 回收

### 5.1 初始化错误表（instanceKlass.cpp:1341-1384）

```cpp
// instanceKlass.cpp:1341
using InitializationErrorTable = HashTable<const InstanceKlass*, OopHandle, ...>;
static InitializationErrorTable* _initialization_error_table;

// instanceKlass.cpp:1344
void InstanceKlass::add_initialization_error(JavaThread* current, Handle exception) {
  // 把"类 → 第一次初始化抛的异常"记入错误表
}
// instanceKlass.cpp:1377
oop InstanceKlass::get_initialization_error(JavaThread* current) {
  // 取回第一次失败的异常，作为后续 NoClassDefFoundError 的 cause
}
```

**为什么记表**：类初始化失败后，**后续所有线程**再触发都会拿到 `NoClassDefFoundError`（:1490-1493），且 cause 是**同一个原始异常**（:1485 取回）——保证错误信息一致、不重复执行 `<clinit>`。

### 5.2 卸载：跟着 ClassLoaderData 走（classLoaderDataGraph.cpp:410）

类的卸载不是「单个类」的事，而是**整批跟加载器走**：

```cpp
// classLoaderDataGraph.cpp:410（GC 时调用）
bool ClassLoaderDataGraph::do_unloading() { ... }
```

- **卸载时机**：GC 发现某 `ClassLoaderData` 不再存活（`ClassLoaderData::is_alive`，classLoaderData.cpp:693——加载器对象 + 其类都不可达）时，整批卸载该加载器加载的所有类。
- **卸载实现**：`ClassLoaderData::unload`（classLoaderData.cpp:604）——清理类、方法、常量池等 Metaspace 元数据，触发 JVMTI `ClassUnload` 事件、`SystemDictionaryShared::handle_class_unloading`（:947）。
- **为什么按加载器批**：同一个加载器的类共享常量池、依赖关系、JIT 代码——拆开单个卸载会留下悬空引用。**JVM 规范不保证类一定被卸载**，是否卸载取决于 GC 与加载器生命周期（这也是「类卸载不可靠」说法的来源——`System.gc` 后老代码仍可能继续使用类）。

> **白话**：卸载 = 公司倒闭整层楼一起清（ClassLoaderData 回收），不是单个工位清。老板（加载器）都消失了，员工（类）自然跟着消失。

---

## 6. JLS 12.4 vs HotSpot 实现：主动使用对照

| JLS 12.4.1 主动使用 | HotSpot 触发点 | 位置 |
|---|---|---|
| `new` 创建实例 | `InterpreterRuntime::_new` → `initialize_preemptable` | interpreterRuntime.cpp:223 / :231 |
| 访问静态字段 | 静态字段解析路径的 `uninitialized_static` 检查 | interpreterRuntime.cpp:741 |
| 调用静态方法 | `invokestatic` 解析路径（同静态字段屏障） | interpreterRuntime.cpp（方法解析链） |
| 反射（forName/newInstance/invoke） | 反射实现最终也走 `InstanceKlass::initialize` | instanceKlass.cpp:961 |
| 初始化子类前初始化父类 | `initialize_impl` Step 7 递归 | instanceKlass.cpp:1539 |
| 编译期常量访问（不触发） | 常量在编译期内联进常量池，无运行时屏障 | — |

**JLS 规范 vs HotSpot 实现的关键差异**：

1. **规范只定义「何时」**，HotSpot 定义「怎么保证并发安全」——`init_lock` + 状态机 + 可重入检测（instanceKlass.cpp:1434-1505）。
2. **规范说失败抛 `ExceptionInInitializerError`**，HotSpot 额外维护**错误表**（:1341）保证后续线程拿到**同一个** cause。
3. **规范不要求卸载**，HotSpot 的卸载是 GC 的副产品（`ClassLoaderDataGraph::do_unloading`），按加载器整批回收。

---

## 7. 与站①②衔接：加载 → 链接 → 初始化 → 卸载

```
站① 加载                站② 链接                  站③ 初始化                卸载（GC）
┌──────────────┐    ┌──────────────────┐    ┌──────────────────┐    ┌──────────────┐
│ 双亲委派      │    │ parse 验明正身    │    │ 主动使用触发       │    │ 加载器不可达   │
│ ↓            │    │ verify 体检       │    │ initialize :961  │    │ ↓            │
│ JVM_Define   │    │ link 接线         │    │ 状态机四态        │    │ do_unloading  │
│ KlassFactory │    │ set linked :1271 │    │ <clinit> :2019   │    │ :410         │
│ ↓            │    │                  │    │ fully_initialized│    │ ClassLoader-  │
│ InstanceKlass│───→│ is_linked = true  │───→│ :1620            │───→│ Data 整批回收 │
└──────────────┘    └──────────────────┘    └──────────────────┘    └──────────────┘
```

- **站②→站③**：`initialize_impl` 第一件事是 `link_class(CHECK)`（instanceKlass.cpp:1422）——**必须先链接才能初始化**（`<clinit>` 会调用本类方法，vtable 必须就绪）。
- **站③→卸载**：初始化完成后类可长期存活；只有当其加载器不可达（GC 判定）才整批卸载——「初始化」和「卸载」之间可以隔很久甚至永不卸载。

---

## 8. 行号速查

| 函数/动作 | 文件:行号 |
|---|---|
| `InstanceKlass::initialize`（入口） | instanceKlass.cpp:961 |
| `InstanceKlass::initialize_impl`（核心） | instanceKlass.cpp:1417 |
| 先 `link_class`（链接前置） | instanceKlass.cpp:1422 |
| 加 `init_lock` | instanceKlass.cpp:1434-1436 |
| 等待其他线程（wait） | instanceKlass.cpp:1442-1451 |
| 递归初始化放行 | instanceKlass.cpp:1454-1462 |
| 已初始化直接回 | instanceKlass.cpp:1465-1473 |
| error 状态抛 NoClassDefFoundError | instanceKlass.cpp:1476-1494 |
| 置 being_initialized + init_thread | instanceKlass.cpp:1498-1499 |
| 初始化父类（递归） | instanceKlass.cpp:1536-1539 |
| 初始化 super interfaces | instanceKlass.cpp:1545-1546 |
| 父类失败处理 | instanceKlass.cpp:1550-1562 |
| 调用 `<clinit>` | instanceKlass.cpp:1578 |
| 成功：fully_initialized | instanceKlass.cpp:1620 |
| 失败：记错误 + ExceptionInInitializerError | instanceKlass.cpp:1633-1645 |
| `set_initialization_state_and_notify`（唤醒） | instanceKlass.cpp:1654-1662 |
| `should_be_initialized` | instanceKlass.cpp:867 |
| `init_lock` 获取 | instanceKlass.cpp:910 |
| 初始化错误表 | instanceKlass.cpp:1341 |
| `add_initialization_error` | instanceKlass.cpp:1344 |
| `get_initialization_error` | instanceKlass.cpp:1377 |
| `class_initializer`（找 `<clinit>`） | instanceKlass.cpp:2010 |
| `call_class_initializer`（执行） | instanceKlass.cpp:2019 |
| `JavaCalls::call`（Java 方法统一入口） | instanceKlass.cpp:2057 |
| 状态机判断（四态） | instanceKlass.hpp:614-618 |
| `InterpreterRuntime::_new`（new 触发） | interpreterRuntime.cpp:223 |
| 初始化屏障（new 内） | interpreterRuntime.cpp:231 |
| 静态字段访问触发 | interpreterRuntime.cpp:741 |
| `ClassLoaderDataGraph::do_unloading`（GC 卸载入口） | classLoaderDataGraph.cpp:410 |
| `ClassLoaderData::unload`（卸载实现） | classLoaderData.cpp:604 |
| `ClassLoaderData::is_alive`（存活判断） | classLoaderData.cpp:693 |

> **类加载三站收官**：站① 加载（双亲委派 + 工匠）→ 站② 链接（验证/接线/准备/懒解析）→ 站③ 初始化（`<clinit>` 触发/并发/卸载）。
> 至此「一条 invokevirtual 的一生」的地基全部铺完——类从字节流到可执行、可回收的完整生命周期，都能在源码里逐行对应了。
