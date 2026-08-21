# 02 · 方法调用全链路：vtable / itable 分派表（klassVtable）

> **快速概览**
> - 源码：`src/hotspot/share/oops/klassVtable.cpp`（1627 行）+ `klassVtable.hpp` + `klass.cpp:1118` + `instanceKlass.cpp:3849-3917` + `instanceKlass.inline.hpp:38` + `klass.inline.hpp:112`
> - 主题：方法调用的**分派表**——vtable（以类为单位）与 itable（以接口为单位）在**链接期构建**、在**运行期被每次调用查询**。
> - 核心结论：vtable 是 `Method*` 数组、O(1) 直达；itable 是"offset 表 + 方法表"、线性扫描。`final/private/static/<init>` 永不进表 → 静态绑定 → 可内联（衔接 08 篇）。
> - 上一篇：`01-linkresolver-symbol-resolution.md`（符号解析）→ 本篇（分派表）→ 下一篇：解释器 invoke 模板 / C2 去虚化。

## 目录

- [一、为什么需要两张表](#一为什么需要两张表)
- [二、内存布局：vtable 紧跟 Klass 头，itable 紧跟 vtable](#二内存布局vtable-紧跟-klass-头itable-紧跟-vtable)
- [三、vtable 构建：三步成表](#三vtable-构建三步成表)
- [四、不进表的四类方法](#四不进表的四类方法)
- [五、覆写合并：同一槽位，胜者替换](#五覆写合并同一槽位胜者替换)
- [六、miranda 与 default：接口方法进 vtable 的两种姿势](#六miranda-与-default接口方法进-vtable-的两种姿势)
- [七、运行期查找：O(1) 的 method_at_vtable](#七运行期查找o1-的-method_at_vtable)
- [八、itable：接口分派表](#八itable接口分派表)
- [九、与 linkResolver 的衔接](#九与-linkresolver-的衔接)
- [十、行号速查表](#十行号速查表)

---

## 一、为什么需要两张表

方法调用分两类语义：

| 语义 | 字节码 | 依据 | 分派表 |
|---|---|---|---|
| **类方法多态** | `invokevirtual` | 接收者的**类** | **vtable** |
| **接口方法多态** | `invokeinterface` | 接收者**实现了哪些接口** | **itable** |

为什么不能一张表搞定？因为**接口可以多继承**：一个类实现多个接口，每个接口各有一组方法。vtable 以"类"为索引单位（子类覆写占同一槽位），而接口方法没法直接映射到类槽位——一个接口方法可能被多个互不相关的类实现，位置各不相同。所以接口需要单独一张表，先**定位接口**，再**查方法**。

> 关键术语：**vtable**（virtual method table，虚方法表）、**itable**（interface method table，接口方法表）、**vtableEntry**（一个槽，就是一个 `Method*` 指针）、**itableOffsetEntry**（接口→方法区偏移记录）、**itableMethodEntry**（一个接口方法槽）。

## 二、内存布局：vtable 紧跟 Klass 头，itable 紧跟 vtable

`InstanceKlass` 对象本体在元空间里，三块紧挨着：

```
┌─────────────────┬──────────────────────────────┬─────────────────────────────┐
│ InstanceKlass 头 │  vtable 区（Method* 数组）    │  itable 区（offset 表+方法表）│
└─────────────────┴──────────────────────────────┴─────────────────────────────┘
        ↑                   ↑                               ↑
   klass.inline.hpp:112  klass.inline.hpp:112-113    instanceKlass.inline.hpp:38
```

- **vtable 起点**：`Klass::start_of_vtable()`（klass.inline.hpp:112-113）返回 `(vtableEntry*)((address)this + vtable_start_offset())` —— 紧跟在 Klass 头之后。
- **vtable 一个槽**：`vtableEntry` 只有一个成员 `Method* _method`（klassVtable.hpp:194-195），即**一个槽就是一个 8 字节指针**。整张 vtable 就是一个 `Method*` 数组。
- **itable 起点**：`InstanceKlass::start_of_itable()`（instanceKlass.inline.hpp:38）返回 `start_of_vtable() + vtable_length()` —— **就在 vtable 尾巴后面**。
- **itable 内部**：头部是 `itableOffsetEntry` 数组（每个 = `{InstanceKlass* _interface; int _offset;}`，klassVtable.hpp:221-241），尾部是 `itableMethodEntry` 数组（每个 = 一个 `Method*`）。offset 表记录"某个接口的方法区从这个类的哪个偏移开始"。

> 注：vtable 长度存在 `Klass::_vtable_len`（klass.hpp:196），itable 长度存在 `InstanceKlass::_itable_len`（instanceKlass.hpp:422）。

## 三、vtable 构建：三步成表

构建发生在**链接期**（`link_class_impl` → `initialize_vtable_and_check_constraints` :615 → `initialize_vtable` :161）。三步：

**① 复制 super 前缀**（`initialize_from_super` :132）
子类 vtable 以父类 vtable 为前缀——`superVtable.copy_vtable_to(table())`（:148），返回复制的条目数。

**② 逐方法判"覆写 or 追加"**（`update_inherited_vtable` :382，主循环在 :199-210）
对每个本类方法：
- 名字+签名匹配到 super 的某个槽 → **覆写**：`put_method_at(target, i)` 替换该槽（:504），并 `set_vtable_index(i)`（:512）；
- 匹配不到 → `allocate_new=true` → 追加到末尾（:206-208）。

**③ default + miranda 收尾**
- `default_methods`（接口的默认方法）走同样的覆写判断（:213-250），新槽记入 `default_vtable_indices`；
- `fill_in_mirandas`（:959）把 miranda 方法追加到 vtable 尾部。

> 结果断言：`initialized == _length`（:264）——算出来的长度必须和实际填入的槽位完全一致，否则 VM 直接 assert。

## 四、不进表的四类方法

`needs_new_vtable_entry`（:633）是**静态判断**（类文件解析期就算 vtable 大小），规则：

| 方法类型 | 处理 | 行号 |
|---|---|---|
| 接口类的方法 | 不进 vtable（接口用 itable） | :639-645 |
| `final` | 永不申请新条目；若覆写 super 方法则**复用其槽** | :647-650 |
| `private` | 不进表（不参与覆写） | :651-652 |
| `static` | 不进表（静态绑定） | :653-654 |
| `<init>` 构造器 | 不进表（永不动态绑定） | :655-656 |
| default 方法 | 不进表（按默认继承规则覆写抽象槽） | :663-669 |
| 无 super（Object） | 需要新条目 | :672-674 |
| `package-private` | **永远自己当根**（不同包不可覆写，需要自己的槽来承载传递覆写） | :678-680 |
| 类链上存在可覆写方法 | 不需要新条目（覆写即复用） | :691-708 |
| super 有匹配 miranda | 不需要新条目（复用 miranda 槽） | :744-748 |

> **final 的深意**：final 方法要么不在表里，要么复用父类槽位——它的调用点在链接期就已确定为"静态绑定"（`nonvirtual_vtable_index`），这就是 08 篇"final 方法可内联"（ciMethod.hpp:353）的底层依据。

## 五、覆写合并：同一槽位，胜者替换

`update_inherited_vtable`（:382）的判断核心：

```
遍历 super vtable 每个槽（:462）：
  名字+签名 匹配 且 不是接口对非 public Object 方法的误配（:476-478）？
    ├─ 非 private 且（可覆写 或 传递覆写成立）？
    │    ├─ 是 → put_method_at(target, i) 替换槽位 + set_vtable_index(i)   ← 覆写成功
    │    └─ 否 → 跳过（allocate_new 保持）
```

- **可覆写判定**（`can_be_overridden` :279）：`protected`/`public` 可覆写；`package-private` 仅同包可覆写（:290）。
- **传递覆写**（`find_transitive_override` :309）：处理"非 javac 一起编译"的怪异层级——比如 `P1.A.pub m` ← `P2.B.pkg-private m` ← `P1.C.pub m`，C.m 覆写的是 A.m 而不是 B.m（:302-308 注释）。沿 super 链往上找，`vtable_index < ssVtable.length()` 才继续（:318）。
- **覆写的副作用**：`set_vtable_index(i)` 把"这个方法的槽位号"刻到 `Method::_vtable_index` 字段上（:512）——**运行期直接查这个号**。

## 六、miranda 与 default：接口方法进 vtable 的两种姿势

接口的抽象方法本身不进 vtable，但当**类实现了一个接口却没实现它的抽象方法**时，类必须有一个槽位来承载"这个方法存在"（否则 `invokevirtual` 无表可查）——这就是 **miranda 方法**。

- **定义**（:786-790 注释）："public abstract 的非 private 接口实例方法，且本类/默认方法/super 都没有覆写它"。
- **追加**：`fill_in_mirandas`（:959）在 vtable 末尾逐个 `put_method_at`。
- **查找**：`index_of_miranda`（:755）**从底部往上搜**（miranda 都在尾部，更快）。

**default 方法**则不同：它是**有实现**的接口方法，由实现类继承后进入 vtable，槽位记录在 `default_vtable_indices`（:244），并参与覆写判断（一个类可以用自己的方法覆写接口 default）。

## 七、运行期查找：O(1) 的 method_at_vtable

```cpp
// klass.cpp:1118
Method* Klass::method_at_vtable(int index) {
  return start_of_vtable()[index].method();   // 就是一次数组寻址
}
```

- 这就是第一站 linkResolver `runtime_resolve_virtual_method` :1464 的落点：`recv_klass->method_at_vtable(vtable_index)`。
- **多态的本质**：`vtable_index` 来自常量池缓存（链接期刻入），对所有子类**同一个号**；`recv_klass` 是接收者的**实际类**——子类覆写占同一槽位，查表即得"实际类型的那一个"。同一句 `dog.speak()`，`Dog` 对象查到自己、`Husky` 对象查到覆写版。
- **热路径成本**：缓存命中后只剩"取接收者 Klass → 数组寻址"两步，比任何解析都快。

## 八、itable：接口分派表

### 8.1 构建（链接期）

**① 算大小**（`compute_itable_size` :1506）：接口数 + 1（末尾留一个空 entry 做终止符）个 offset entry + 所有接口方法总数个 method entry。

**② 铺 offset 表**（`setup_itable_offset_table` :1519）：遍历 `transitive_interfaces`，每个接口一个 offset entry，记录它的方法区偏移。

**③ 接口方法编号**（`assign_itable_indices_for_interface` :1244）：给每个接口的**需要分派的方法**编 0..n-1 号：
- 不需要编号的：`static`（:1233）、`private`（:1234）、`<init>`（:1235）、`<clinit>`（:1236）；
- 已有 vtable index 的（如从 Object 重声明的 `toString`）不碰（:1274-1283）。

**④ 填方法槽**（`initialize_itable_for_interface` :1316）：每个接口方法 → `LinkResolver::lookup_instance_method_in_klasses`（:1334，**skip private**——私有类方法不可能是接口实现）在本类找实现：
- 找到且 public 非抽象 → 填槽 `initialize(_klass, target)`（:1355）；
- 找不到/抽象 → 留空（调用时抛 **AbstractMethodError**，:1337-1338）；
- 找到但非 public → 塞一个抛 **IllegalAccessError** 的替身方法（:1339-1342）。

### 8.2 运行期查找：线性扫描

```cpp
// instanceKlass.cpp:3876 method_at_itable_or_null
klassItable itable(this);
for (int i = 0; i < itable.size_offset_table(); i++) {
  itableOffsetEntry* offset_entry = itable.offset_entry(i);
  if (offset_entry->interface_klass() == holder) {   // 找到目标接口
    implements_interface = true;
    itableMethodEntry* ime = offset_entry->first_method_entry(this);
    return ime[index].method();                       // 再按方法号直取
  }
}
```

- **为什么线性扫描**：接口可多继承、每个类实现的接口集合都不同，没法像 vtable 一样用固定 index 直达——只能先**遍历 offset 表找接口**，再在接口自己的方法区里按编号直取。
- **找不到接口**（接收者没实现该接口）→ 上层 `method_at_itable`（:3849）抛 **IncompatibleClassChangeError**（:3872）；
- **接口找到了但槽为空** → 抛 **AbstractMethodError**（:3858）——正好对应 8.1 ④ 的"留空"。

### 8.3 接口方法找 vtable 槽

`vtable_index_of_interface_method`（instanceKlass.cpp:3891）：default 方法先查 `default_methods` 数组取 `default_vtable_indices`（:3901-3910），查不到再走 miranda：`vt.index_of_miranda(name, signature)`（:3914）——这就是第一站 :1440 的出处。

## 九、与 linkResolver 的衔接

| linkResolver 位置 | 做什么 | klassVtable 侧 |
|---|---|---|
| :1450 `vtable_index` | 拿接口方法的 vtable 号 | `vtable_index_of_interface_method`（instanceKlass.cpp:3891） |
| :1464 `method_at_vtable` | 按接收者实际类型查表 | `Klass::method_at_vtable`（klass.cpp:1118）O(1) |
| :1457 `nonvirtual_vtable_index` | final/private → 静态绑定 | `needs_new_vtable_entry`（:647-656）final/private 不进表 |
| :1561 `lookup_instance_method_in_klasses` | 接口调用找实现 | itable 填槽用的**同一个函数**（:1334） |
| :1599-1617 接口三分支 | vtable/itable/nonvirtual 三选一 | itable 表（本文件 :1107-1372） |

**一句话闭环**：符号解析（01）问"字面上指向谁"，分派表（02）回答"实际执行谁、去哪查"——vtable 一个数直达，itable 先找接口再找方法。

## 十、行号速查表

| 行号 | 内容 |
|---|---|
| klassVtable.cpp:66 | `compute_vtable_size_and_num_mirandas` vtable 大小计算 |
| klassVtable.cpp:132 | `initialize_from_super` 复制 super 前缀 |
| klassVtable.cpp:161 | `initialize_vtable` vtable 构建总流程 |
| klassVtable.cpp:279 | `can_be_overridden` 可覆写判定 |
| klassVtable.cpp:309 | `find_transitive_override` 传递覆写 |
| klassVtable.cpp:382 | `update_inherited_vtable` 覆写合并核心 |
| klassVtable.cpp:633 | `needs_new_vtable_entry` 静态判断（final/private/static 不进表） |
| klassVtable.cpp:755 | `index_of_miranda` miranda 槽查找 |
| klassVtable.cpp:959 | `fill_in_mirandas` miranda 追加 |
| klassVtable.cpp:1107 | `klassItable` 构造（重建视图） |
| klassVtable.cpp:1134 | `initialize_itable` itable 构建 |
| klassVtable.cpp:1232 | `interface_method_needs_itable_index` 哪些接口方法需要编号 |
| klassVtable.cpp:1244 | `assign_itable_indices_for_interface` 接口方法编号 |
| klassVtable.cpp:1316 | `initialize_itable_for_interface` 填槽（找实现/留空/塞 IAE 替身） |
| klassVtable.cpp:1506 | `compute_itable_size` itable 大小 |
| klassVtable.cpp:1519 | `setup_itable_offset_table` offset 表铺设 |
| klass.cpp:1118 | `method_at_vtable` 运行期 O(1) 查找 |
| instanceKlass.cpp:3849 | `method_at_itable`（空槽→AME / 未实现→ICCE） |
| instanceKlass.cpp:3876 | `method_at_itable_or_null` 线性扫描 offset 表 |
| instanceKlass.cpp:3891 | `vtable_index_of_interface_method` default→miranda 兜底 |
| klass.inline.hpp:112 | `start_of_vtable` vtable 起点 |
| instanceKlass.inline.hpp:38 | `start_of_itable` itable 起点（vtable 尾） |
| klassVtable.hpp:194-195 | `vtableEntry` = 单个 `Method*` |
| klassVtable.hpp:221-241 | `itableOffsetEntry` = 接口 + 偏移 |
