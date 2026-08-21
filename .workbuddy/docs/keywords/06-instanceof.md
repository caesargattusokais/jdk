# instanceof：类型检查的 HotSpot 全链路

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Java 关键字源码跟读 · 第 06 篇（[回到系列索引](README.md)）
> 前置：[01 关键字全景](01-keywords-overview.md) · [05 static 类初始化](05-static.md)

---

## 快速概览

- **一句话结论**：`instanceof` 是机制型关键字的代表——字节码 `instanceof 0xc1`（JVM 里 `_instanceof = 193`）在模板解释器里下钻成一条**汇编级子类型检查** `check_klass_subtype`，最终落到 Klass 的两条通道：**超类显示表比对（O(1)）** 或 **secondary_supers 哈希表查找（接口）**；C2 则把它优化成**三路分支 merge**（null / 命中 / 未命中），还能用 profile 数据做动态类型推断。
- **与 `checkcast` 的本质区别**（本篇核心认知）：
  1. **栈效果不同**：`instanceof` 消耗对象引用、压入 `int`（0/1），栈型 `atos→itos`；`checkcast` 检查后**对象原样留下**，栈型 `atos→atos`。
  2. **失败行为不同**：`instanceof` 失败返回 0；`checkcast` 失败抛 `ClassCastException`（解释器直接 `jump` 到 `_throw_ClassCastException_entry`）。
  3. **null 语义不同**：两者对 null 都"放行"（instanceof → false，checkcast → null 原样通过）。
  4. **C2 用途不同**：`checkcast` 生成 `cast` 节点，**把对象的类型信息收窄**供后续优化使用；`instanceof` 生成 `bool` 值，不改变对象类型。
- **与 Object/系列主线衔接**：`instanceof` 的"java_mirror 双身份"（`klass.inline.hpp:96-98`，Object 系列已读）在这里闭环——解释器从对象取 Klass 用的是 `load_klass`，与 getClass 返回的 mirror 是同一块数据的不同视图。
- **JDK 28 工程细节**：接口检查不再线性扫数组——`secondary_supers` 是**带占用位图的哈希表**（`SECONDARY_SUPERS_TABLE_SIZE` 槽位），位图为 0 可**确定性跳过**，满 2 槽后回退线性查找。

---

## 目录

1. [字节码层：0xc1 vs 0xc0](#一字节码层0xc1-vs-0xc0)
2. [模板解释器：instanceof() 逐行拆解](#二模板解释器instanceof-逐行拆解)
3. [汇编核心：check_klass_subtype 快慢双路径](#三汇编核心check_klass_subtype-快慢双路径)
4. [Klass 层算法：上溯超类链 vs 双通道](#四klass-层算法上溯超类链-vs-双通道)
5. [接口检查的工程秘密：secondary_supers 哈希表](#五接口检查的工程秘密secondary_supers-哈希表)
6. [C2 下钻：gen_instanceof 三路 merge](#六c2-下钻gen_instanceof-三路-merge)
7. [instanceof vs checkcast 对比表](#七instanceof-vs-checkcast-对比表)
8. [JDK 28 vs 教科书差异](#八jdk-28-vs-教科书差异)
9. [验证实验](#九验证实验)
10. [与系列主线闭环](#十与系列主线闭环)

---

## 一、字节码层：0xc1 vs 0xc0

JVM 规范里 `instanceof` 与 `checkcast` 是**相邻的两个字节码**，操作数格式完全相同（`opcode + 2 字节常量池索引`），区别只在栈语义和失败语义。

```cpp
// src/hotspot/share/interpreter/bytecodes.hpp:236-237
_checkcast            = 192, // 0xc0
_instanceof           = 193, // 0xc1
```

javac 的生成规则（编译期语义，读 javac 而不是 HotSpot）：

| Java 代码 | 生成的字节码 | 为什么 |
|---|---|---|
| `b = obj instanceof T` | `instanceof`（0xc1） | 需要 boolean 结果 |
| `T t = (T) obj` | `checkcast`（0xc0） | 需要收窄类型并保留对象 |
| `(T) obj` 用于调用/赋值 | `checkcast`（0xc0） | 同上 |
| 模式匹配 `if (obj instanceof T t)` | `instanceof`（0xc1）+ 成功后 `astore` | JDK 16+，见 §6 |

> **关键认知**：`instanceof` 的"是否命中"是**运行时类型检查**，而不是"等于"——`String` 的实例对 `Object` 也是 true。这个"子类型"判定就是本系列要下钻的 HotSpot 核心。

## 二、模板解释器：instanceof() 逐行拆解

解释器模板在 `src/hotspot/cpu/x86/templateTable_x86.cpp`（注意在 cpu 目录，不在 share）。

### 2.1 instanceof()（templateTable_x86.cpp:3934）

```cpp
void TemplateTable::instanceof() {
  transition(atos, itos);            // 栈型：对象引用 → int（0/1）
  Label done, is_null, ok_is_subtype, quicked, resolved;
  __ testptr(rax, rax);              // 对象在 rax
  __ jcc(Assembler::zero, is_null);  // null → 直接出 0（不检查！）

  __ get_cpool_and_tags(rcx, rdx);   // 取常量池 + tag 数组
  __ get_unsigned_2_byte_index_at_bcp(rbx, 1); // rbx = 常量池索引
  __ movzbl(rdx, Address(rdx, rbx, Address::times_1, Array<u1>::base_offset_in_bytes()));
  __ cmpl(rdx, JVM_CONSTANT_Class);  // tag 是否已是 JVM_CONSTANT_Class（已快速化）
  __ jcc(Assembler::equal, quicked);

  __ push(atos);                     // 保存 receiver（对 GC 可见）
  call_VM(noreg, CAST_FROM_FN_PTR(address, InterpreterRuntime::quicken_io_cc));
  __ get_vm_result_metadata(rax);    // 取回解析后的 Klass
  __ pop_ptr(rdx);                   // 恢复 receiver
  __ verify_oop(rdx);
  __ load_klass(rdx, rdx, rscratch1);// rdx = 对象的实际 Klass
  __ jmpb(resolved);

  __ bind(quicked);                  // 已快速化
  __ load_klass(rdx, rax, rscratch1);// rdx = 子类 Klass
  __ load_resolved_klass_at_index(rax, rcx, rbx); // rax = 目标 superklass

  __ bind(resolved);
  __ gen_subtype_check(rdx, ok_is_subtype); // 核心检查（§3）

  __ xorl(rax, rax);                 // 失败：rax = 0
  __ jmpb(done);
  __ bind(ok_is_subtype);
  __ movl(rax, 1);                   // 成功：rax = 1
  ...
  __ bind(done);
}
```

执行流拆解为 5 段：

| 段 | 动作 | 说明 |
|---|---|---|
| **① null 短路**（3937-3938） | `testptr` + `jcc zero` | **null 根本不做类型检查**，直接走 `is_null` 出 0——`null instanceof T == false` 是语言语义，但 VM 层面是"跳过检查"实现的 |
| **② 常量池快速化**（3940-3951） | 查 tag 是否 `JVM_CONSTANT_Class` | 首次执行时常量池条目还是 `JVM_CONSTANT_Utf8`/`ClassRef`，需 `quicken_io_cc` 解析成已解析的 Class；**quicken 后 tag 变为 `JVM_CONSTANT_Class`，下次执行直接走 `quicked` 分支** |
| **③ 取两个 Klass**（3957/3962-3963） | `load_klass` + `load_resolved_klass_at_index` | 子类 Klass = 对象头里 `_klass` 字段（`load_klass`）；目标 superklass = 常量池已解析条目 |
| **④ 子类型检查**（3969） | `gen_subtype_check(rdx, ok_is_subtype)` | 汇编宏，§3 拆解 |
| **⑤ 出结果**（3972-3976） | `rax = 0/1` | 失败 `xorl`，成功 `movl 1` |

### 2.2 checkcast()（templateTable_x86.cpp:3879）

对照看差异就非常清楚了：

```cpp
void TemplateTable::checkcast() {
  transition(atos, atos);            // ← 栈型不变！对象留下
  ...
  __ gen_subtype_check(rbx, ok_is_subtype); // rbx = 子类
  __ push_ptr(rdx);                  // 失败：把对象压回栈
  __ jump(RuntimeAddress(Interpreter::_throw_ClassCastException_entry)); // ← 抛异常
  __ bind(ok_is_subtype);
  __ mov(rax, rdx);                  // 成功：对象放回 rax
  ...
}
```

| 维度 | `instanceof` | `checkcast` |
|---|---|---|
| 栈型 | `atos→itos`（对象换 int） | `atos→atos`（对象原样） |
| 失败 | `rax=0`，继续执行 | 压栈后 **jump 抛 ClassCastException** |
| null | 短路出 0 | 短路放行（`is_null` → `done`，rax 仍是 null 对象） |

> 注：两个模板用同一个 `gen_subtype_check` 宏（`interp_masm_x86.cpp:586`），它先做 `profile_typecheck`（收集类型检查画像，供 C2 用），再调 `check_klass_subtype`。

## 三、汇编核心：check_klass_subtype 快慢双路径

`gen_subtype_check`（`interp_masm_x86.cpp:586-600`）薄薄一层，真正干活的是 `MacroAssembler::check_klass_subtype`（`src/hotspot/cpu/x86/macroAssembler_x86.cpp:4047`）：

```cpp
void MacroAssembler::check_klass_subtype(Register sub_klass,
                                         Register super_klass,
                                         Register temp_reg,
                                         Label& L_success) {
  Label L_failure;
  check_klass_subtype_fast_path(sub_klass, super_klass, temp_reg,
                                &L_success, &L_failure, nullptr);
  check_klass_subtype_slow_path(sub_klass, super_klass, temp_reg,
                                noreg, &L_success, nullptr);
  bind(L_failure);
}
```

**快路径**（`macroAssembler_x86.cpp:4058`）的汇编逻辑是经典三段：

```
① cmpptr(sub_klass, super_klass); jcc(equal, L_success);
   // 自己 == 目标（如 String[] 对 String[]）→ 立即成功
   // 注释明确说：self-check 让"数组-of-接口"可以共享 secondary_supers 数组

② movl(temp_reg, [super_klass + super_check_offset_offset]);
   cmpptr(super_klass, [sub_klass + temp_reg]);  // 显示表比对
   jcc(equal, L_success);
   // 目标类的 super_check_offset 指向子类 Klass 里的一个槽位
   // 那个槽位要么存"目标超类"（命中），要么存 secondary_super_cache

③ 走到 L_failure（普通类）或 L_slow_path（super_check_offset == secondary 偏移时）
```

关键概念 **`super_check_offset`**：每个 Klass 都有一个 `super_check_offset` 字段（`klass.hpp` 的 `_super_check_offset`），它的值有两个可能：

- **非接口的普通类**：偏移指向子类 Klass 内的**主超类显示表**（primary super array 的某个槽，实际是"super 链上的第 N 级"），检查 = 一次内存读 + 一次比较，**O(1)**；
- **接口**（以及数组元素是接口的场景）：偏移恰好等于 `secondary_super_cache_offset`——这时快路径读到的槽是**二级超类缓存**，可能缓存了最近命中的接口；没命中就进**慢路径**（§5）。

慢路径（`check_klass_subtype_slow_path`）就是调用 `Klass::search_secondary_supers` 的 C++ 函数（通过 stub 例程或直接调用），返回是否在接口集合中。

> **教科书 vs 现实**：教科书说"instanceof 上溯父类链 O(depth)"——那只是 `is_subclass_of` 的朴素描述。**真正的热路径是 O(1) 显示表比对**（一次 load + cmp），上溯链只在极少数非热点路径出现。这是本篇第一个"教科书差异"。

## 四、Klass 层算法：上溯超类链 vs 双通道

慢路径/辅助代码最终到 Klass 层的两个函数：

### 4.1 is_subclass_of：朴素的超类链上溯（klass.cpp:141）

```cpp
bool Klass::is_subclass_of(const Klass* k) const {
  // Run up the super chain and check
  if (this == k) return true;
  Klass* t = const_cast<Klass*>(this)->super();
  while (t != nullptr) {
    if (t == k) return true;
    t = t->super();
  }
  return false;
}
```

这就是教科书里的算法：从自己出发，沿 `_super` 指针一路向上。复杂度 O(继承深度)。**注意它只认 super 链，不认接口**——接口检查要走另一条路（§5）。

### 4.2 is_subtype_of：双通道分派（klass.inline.hpp:121）

```cpp
// subtype check: true if is_subclass_of, or if k is interface and receiver implements it
inline bool Klass::is_subtype_of(Klass* k) const {
  const juint off = k->super_check_offset();
  const juint secondary_offset = in_bytes(secondary_super_cache_offset());
  if (off == secondary_offset) {
    return search_secondary_supers(k);   // 通道 B：接口集合查找
  } else {
    Klass* sup = *(Klass**)( (address)this + off ); // 通道 A：显示表 O(1)
    return (sup == k);
  }
}
```

**分派依据就是 §3 的 `super_check_offset`**：

- 目标 `k` 是普通类 → `off` 是显示表偏移 → 直接读子类 Klass 对应槽位比较 → **O(1)**；
- 目标 `k` 是接口 → `off == secondary_offset` → 走 `search_secondary_supers` → 哈希表查找。

这个设计的美妙之处：**把"目标是什么类型"编码进了目标自身的 super_check_offset**，检查代码无需分支判断目标是不是接口——一次读偏移、一次比较就完成分派。

## 五、接口检查的工程秘密：secondary_supers 哈希表

接口的 `instanceof` 是真正的难点：一个类可以实现任意多个接口，且接口自己可以继承接口（超接口）。朴素做法是扫 `_secondary_supers` 数组（所有直接/间接接口的扁平列表）。JDK 28 的实现在此之上做了哈希表优化：

### 5.1 数据结构

- `_secondary_supers`：ObjArray，存"直接接口 + 超接口"的扁平列表（类初次加载时计算）；
- `_secondary_supers_bitmap`（`uintx`）：`SECONDARY_SUPERS_TABLE_SIZE`（默认 64，`klass.hpp`）位组成的**占用位图**，第 i 位 = 哈希表槽 i 是否被占用；
- `_hash_slot`：每个 Klass 一个 8 位哈希槽号（`uint8_t slot = k->_hash_slot`）。

### 5.2 哈希查找（klass.inline.hpp:134-167）

```cpp
inline bool Klass::lookup_secondary_supers_table(Klass* k) const {
  uintx bitmap = _secondary_supers_bitmap;
  uint8_t slot = k->_hash_slot;
  uintx shifted_bitmap = bitmap << (highest_bit_number - slot);
  // 位图为 0 → 确定不在 → 直接返回 false（O(1) 拒绝！）
  if (((shifted_bitmap >> highest_bit_number) & 1) == 0) {
    return false;
  }
  // 计算首个探测位
  int index = population_count(shifted_bitmap) - 1;
  if (secondary_supers()->at(index) == k) return true;  // 一次命中
  // 否则线性探测，位图第 1 位为 0 即终止
  bitmap = rotate_right(bitmap, slot);
  if ((bitmap & 2) == 0) return false;
  return fallback_search_secondary_supers(k, index, bitmap);
}
```

三个优化层次：

| 层次 | 条件 | 代价 |
|---|---|---|
| **位图拒绝** | 目标接口的哈希槽在 bitmap 里为 0 | **O(1)**，且是确定性失败（不用探测） |
| **一次命中** | `population_count(shifted_bitmap)-1` 处正好是目标 | O(1) |
| **线性探测** | `fallback_search_secondary_supers`（klass.cpp:175） | 平均 O(1)，带旋转位图提前终止 |

### 5.3 兜底与校验

- 哈希表接近满（`length() > SECONDARY_SUPERS_TABLE_SIZE - 2`）时，`fallback_search_secondary_supers` 直接退化为**线性扫描**（klass.cpp:178-180）；
- 产品模式下有 `VerifySecondarySupers` 校验：哈希结果必须与线性扫描一致（klass.inline.hpp:176-183）。

> **结论**：JDK 28 的接口 instanceof 是"**位图 + 哈希 + 探测**"三级，比教科书的"线性扫接口数组"快一个数量级。这是本篇第二个（也是最重要的）教科书差异。

## 六、C2 下钻：gen_instanceof 三路 merge

C2 编译器对 `instanceof` 的处理在 `GraphKit::gen_instanceof`（`src/hotspot/share/opto/graphKit.cpp:3576`，`library_call.cpp:4519` 是 `inline_instanceof` 的调用点）。

### 6.1 三路分支结构（graphKit.cpp:3584-3607）

```
enum { _obj_path = 1, _fail_path, _null_path, PATH_LIMIT };
RegionNode* region = new RegionNode(PATH_LIMIT);
Node*       phi    = new PhiNode(region, TypeInt::BOOL);
```

C2 把 instanceof 建模成**三路 merge**：

| 路径 | 值 | 来源 |
|---|---|---|
| `_null_path` | 0 | `null_check_oop`（graphKit.cpp:3599）——对象为 null 时短路 |
| `_fail_path` | 0 | `gen_subtype_check` 的未命中出口（graphKit.cpp:3655） |
| `_obj_path` | 1 | 检查命中的主路径（graphKit.cpp:3651） |

### 6.2 静态子类型检查（graphKit.cpp:3616-3624）

```cpp
bool known_statically = false;
if (improved_klass_ptr_type->singleton()) {
  const TypeKlassPtr* subk = _gvn.type(obj)->is_oopptr()->as_klass_type();
  if (subk != nullptr && subk->is_loaded()) {
    int static_res = C->static_subtype_check(improved_klass_ptr_type, subk);
    known_statically = (static_res == Compile::SSC_always_true
                     || static_res == Compile::SSC_always_false);
  }
}
```

如果 **Ideal 类型系统已经能确定结果**（比如对象声明类型就是目标类型的子类，或者类型系统证明不可能），整个检查被折叠成常量 `true/false`——运行时零开销。

### 6.3 画像驱动的动态类型（graphKit.cpp:3626-3641）

```cpp
ciKlass* spec_obj_type = obj_type->speculative_type();
if (spec_obj_type != nullptr || (ProfileDynamicTypes && data != nullptr)) {
  Node* cast_obj = maybe_cast_profiled_receiver(not_null_obj, nullptr, spec_obj_type, safe_for_replace);
  ...
  if (cast_obj != nullptr) not_null_obj = cast_obj;   // 收窄后检查更快
}
```

解释器执行的 `profile_typecheck`（§2.1 注）收集的画像在这里被消费：**如果画像显示对象几乎总是某具体类型，就把对象先 cast 成那个类型再检查**，检查常常变成一次指针比较。

### 6.4 与 checkcast 的 C2 差异

- `gen_checkcast`（graphKit.cpp:3684）生成 **cast 节点**（`CastPP` 等），成功路径上对象的类型被**收窄**，后续的字段访问/方法调用/虚分派都能吃这个更精确的类型——这是 JIT 类型优化的主要来源；
- `gen_instanceof` 只产出 bool 值，**不改对象的类型**（除了 `safe_for_replace` 时对 map 的投机替换，graphKit.cpp:3665-3668）。

## 七、instanceof vs checkcast 对比表

| 维度 | `instanceof` | `checkcast` |
|---|---|---|
| 字节码 | `0xc1`（bytecodes.hpp:237） | `0xc0`（bytecodes.hpp:236） |
| 栈效果 | 对象 → int(0/1)，`atos→itos` | 对象原样保留，`atos→atos` |
| 失败行为 | 返回 0，继续执行 | 抛 `ClassCastException` |
| null | → false（短路） | null 放行 |
| 解释器模板 | `templateTable_x86.cpp:3934` | `templateTable_x86.cpp:3879` |
| 核心检查 | `gen_subtype_check`（同一宏） | `gen_subtype_check`（同一宏） |
| C2 入口 | `gen_instanceof`（graphKit.cpp:3576） | `gen_checkcast`（graphKit.cpp:3684） |
| C2 产物 | bool 值，三路 merge | cast 节点，收窄对象类型 |
| 用途 | 条件判断、模式匹配 | 强转、数组存储、泛型擦除后收窄 |

## 八、JDK 28 vs 教科书差异

| 教科书说法 | JDK 28 真相 | 证据 |
|---|---|---|
| instanceof 上溯父类链，O(深度) | 热路径是 **O(1) 显示表比对**；上溯链只在慢路径/工具代码用 | `klass.inline.hpp:121-131`、`macroAssembler_x86.cpp:4058` |
| 接口检查扫接口数组 O(n) | **位图 + 哈希 + 探测**，位图为 0 可确定性拒绝 | `klass.inline.hpp:134-167` |
| instanceof 和 checkcast 差不多 | 栈效果、失败行为、C2 产物完全不同 | 对比表 §7 |
| 类型检查每次都要跑 | C2 可**静态折叠**（类型系统证明）或**画像收窄** | graphKit.cpp:3616-3641 |
| null instanceof T 是"语言语义" | VM 层面是**跳过检查**（`testptr` + 短路） | templateTable_x86.cpp:3937-3938 |
| 首次执行直接检查 | 常量池要先 **quicken**（`quicken_io_cc`），第二次才走快路径 | templateTable_x86.cpp:3951 |

## 九、验证实验

用自己编译的 JDK 28 验证（参考系列 01 的实验方法）：

```java
// Instof.java
public class Instof {
    static boolean m1(Object o) { return o instanceof String; }           // 类检查
    static boolean m2(Object o) { return o instanceof Runnable; }         // 接口检查
    static boolean m3(Object o) { return o instanceof Comparable<?>; }    // 接口(泛型擦除)
    public static void main(String[] a) {
        Object s = "x", n = null;
        for (int i = 0; i < 100_000; i++) {  // 预热触发 JIT
            m1(s); m2(s); m3(s); m1(n);
        }
        System.out.println(m1(s) + " " + m2(s) + " " + m3(s) + " " + m1(n));
    }
}
```

1. **看字节码**：`javap -c -v Instof` → 三处分别出现 `instanceof #N`（0xc1），验证 §1；
2. **解释器画像**：`java -XX:+UnlockDiagnosticVMOptions -XX:+PrintInterpreter` 或 `-Xlog:interpreter` 观察 `quicken_io_cc` 只发生一次（首次执行快速化）；
3. **C2 静态折叠**：`java -XX:+PrintAssembly`（需 hsdis）看 `m1` 在热身后是否只剩 `cmp` 甚至被常量折叠——对象类型已知为 String 时检查可消除；
4. **接口哈希**：`-XX:+UnlockDiagnosticVMOptions -XX:+PrintSecondarySupers`（若存在）或 `-XX:VerifySecondarySupers` 开启产品校验，观察接口检查走 `search_secondary_supers`；
5. **对比异常路径**：把 `m1` 换成强转 `(String) o`，`-XX:+TraceExceptions` 看 checkcast 失败抛 `ClassCastException` 的 trace。

## 十、与系列主线闭环

- **Object 主线**：`getClass()` 的 mirror 双身份（`klass.inline.hpp:96-98`）与 `load_klass` 是同一块数据——instanceof 取类型不用调 Java 方法，直接读对象头 `_klass`，这就是"VM 特权"；
- **new（04）**：对象头的 `mark = prototype` 出生即 unlocked，而 `_klass` 字段在 `MemAllocator` 里被填上 Klass 指针——instanceof 检查的就是它；
- **static（05）**：类未初始化时 new 会触发 clinit；而 instanceof **不触发类初始化**（JLS 规定，类型检查不构成主动使用）——VM 里 `load_resolved_klass_at_index` 只解析不初始化；
- **下一站（07）**：异常处理全家桶——try/catch/finally 的异常表结构，athrow 的 handler 查找，与 checkcast 的"查表抛异常"是同一套机制。

---

> 下一篇：[07 异常处理全家桶](07-exceptions.md) —— try / catch / finally / throw / throws
