# hashCode() 身份哈希源码跟读记录

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Object 源码跟读 · 第 03 篇（[回到系列索引](README.md)）
> 主题：从 `Object.hashCode()` 出发，穿透 Java → JNI / JIT → HotSpot 核心算法
> 阅读前置：已能编译、已生成官方 IDEA 工程（bin/idea.sh）

---

## 快速概览

- **一句话结论**：对象的 identity hash 保存在**对象头 mark word** 里。首次调用时由 `get_next_hash` 生成，通过 **CAS 原子安装**进对象头；之后任何一次调用都直接读对象头返回，不再生成。
- **两条执行路径**：解释执行走 JNI（`jvm.cpp`）；JIT 编译后走 intrinsic（`library_call.cpp`），最终汇聚到同一个函数 `ObjectSynchronizer::FastHashCode`。
- **核心开关**：`-XX:hashCode=N` 切换 6 种生成算法，默认 Marsaglia xor-shift（线程本地状态，无锁无竞争）。
- **阅读顺序建议**：`Object.java` → `jvm.cpp` → `synchronizer.cpp`（重点）→ `markWord.hpp` → `library_call.cpp`。

> ▶ **配套交互动画**：[hashCode 身份哈希 · mark word 流程](03-hashCode-markword-animation.html)（8 步逐步播放，Space 播放/暂停，← → 步进，R 重置；每步代码面板引用下方对应行号）

### 核心文件索引

| 文件 | 关键行 | 内容 |
|---|---|---|
| `src/java.base/share/classes/java/lang/Object.java` | 130–131 | `hashCode` 声明（`native` + `@IntrinsicCandidate`） |
| `src/hotspot/share/classfile/javaClasses.cpp` | 92–104 | **native 绑定注册表**（VM 静态注册，见系列总览 05） |
| `src/hotspot/share/prims/jvm.cpp` | 787 / 793 / 836 | JNI 入口 `JVM_IHashCode` / valhalla 分支 / 转发 `FastHashCode` |
| `src/hotspot/share/runtime/synchronizer.cpp` | 678–700 | `FastHashCode` 核心循环（CAS 安装） |
| `src/hotspot/share/runtime/synchronizer.cpp` | 638–676 | `get_next_hash` 六种生成算法 |
| `src/hotspot/share/oops/markWord.hpp` | 141–188, 293–298 | mark word 布局与 hash 读写 |
| `src/hotspot/share/oops/oop.cpp` | 118–122 | `slow_identity_hash`（intrinsic 回退） |
| `src/hotspot/share/oops/oop.inline.hpp` | 425 | `identity_hash()` 内联入口 |
| `src/hotspot/share/opto/library_call.cpp` | 252 | C2 intrinsic 分发 |
| `src/hotspot/share/opto/c2compiler.cpp` | 620 | C2 `_hashCode` 内建识别 |
| `src/hotspot/share/runtime/globals.hpp` | 294 | `InlineObjectHash` 总开关 |
| `src/hotspot/share/classfile/vmIntrinsics.cpp` | 469 | intrinsic 启用检查 |

### 目录

1. [阅读入口：Java 层声明](#一阅读入口java-层声明)
2. [JVM 入口：两条路径殊途同归](#二jvm-入口两条路径殊途同归)
3. [核心循环：FastHashCode 与 CAS 安装](#三核心循环fasthashcode-与-cas-安装)
4. [哈希生成：get_next_hash 六种算法](#四哈希生成get_next_hash-六种算法)
5. [对象头：mark word 布局与读取](#五对象头mark-word-布局与读取)
6. [JIT intrinsic 路径](#六jit-intrinsic-路径)
7. [验证实验](#七验证实验)
8. [全链路图](#八全链路图)

---

## 一、阅读入口：Java 层声明

`src/java.base/share/classes/java/lang/Object.java:130-131`：

```java
@IntrinsicCandidate
public native int hashCode();
```

两个关键信息：

- **`native`**：实现不在 Java 层，去 C++（HotSpot）找。
- **`@IntrinsicCandidate`**：JIT 编译到热点时会被**内建替换**（intrinsic），不走 JNI 调用开销。JDK 9 引入，是读 JDK 源码时最常见的注解之一。

## 二、JVM 入口：两条路径殊途同归

### 2.1 JNI 路径（解释执行 / 未内联时）

入口 `src/hotspot/share/prims/jvm.cpp:787`：

```cpp
JVM_ENTRY(jint, JVM_IHashCode(JNIEnv* env, jobject handle))
```

- **789–791**：`handle == nullptr` 时返回 0。
- **793–822**：Valhalla inline class（value class）特判分支——value object 无 identity，identity hash 由 `ValueObjectMethods.valueObjectHashCode` 计算（810 行）并 CAS 安装，不走 `FastHashCode`。JDK 28 引入，启用 `-XX:+EnableValhalla` 相关实验特性后生效。
- **823–836**：普通对象（identity object）的转发：

```cpp
} else {
    return checked_cast<jint>(ObjectSynchronizer::FastHashCode(THREAD, obj));  // 836
}
```

**JDK 28 的重要变化**：`Object.hashCode` 是 native，但 `Object.java` 里**已经没有 `registerNatives()`**（JDK 8 时代有）。它的绑定由 VM 启动早期静态完成——`javaClasses.cpp:94` 把 `hashCode` 注册到 `JVM_IHashCode` 函数指针。详细机制见系列总览 [05 节](01-object-overview.md)。

### 2.2 JIT intrinsic 路径（编译后）

C2 编译时把 `hashCode()` 调用内联掉，分发 `src/hotspot/share/opto/library_call.cpp:252`：

```cpp
case vmIntrinsics::_hashCode:
  return inline_native_hashcode(intrinsic()->is_virtual(), !is_static);
```

内联生成失败时的回退实现 `src/hotspot/share/oops/oop.cpp:118-122`：

```cpp
intptr_t oopDesc::slow_identity_hash() {
  Thread* current = Thread::current();
  return ObjectSynchronizer::FastHashCode(current, this);
}
```

**跟读规律**：`native` 方法先在 `prims/jvm.cpp` 找 JNI 入口，再看是否命中 intrinsic。两条路最终都汇到同一个函数——`FastHashCode`。

## 三、核心循环：FastHashCode 与 CAS 安装

`src/hotspot/share/runtime/synchronizer.cpp:678-700`：

```cpp
while (true) {
    markWord temp, test;
    intptr_t hash;
    markWord mark = obj->mark_acquire();          // ① 读对象头
    // The hash is located in the object header.   // ← 686 行注释
    hash = mark.hash();                           // ② 已有 hash？
    if (hash != 0) {                              // ③ 有 → 直接返回
      return hash;
    }
    hash = get_next_hash(current, obj);           // ④ 无 → 生成新 hash
    temp = mark.copy_set_hash(hash);              // ⑤ 合并进对象头副本
    test = obj->cas_set_mark(temp, mark);         // ⑥ CAS 原子安装
    if (test == mark) {                           // ⑦ 安装成功 → 返回
      return hash;
    }
                                                  // ⑧ CAS 失败 → 重试
}
```

要点：

- **hash 存在对象头里**（686 行注释原话 "The hash is located in the object header"），所以同一个对象 `hashCode()` 只生成一次。
- `mark_acquire()` + `cas_set_mark()` 是无锁并发安全的标准姿势：CAS 失败说明有别的线程抢先安装了 hash，循环重试即可，无需加锁。

## 四、哈希生成：get_next_hash 六种算法

`src/hotspot/share/runtime/synchronizer.cpp:638-676`，通过 `-XX:hashCode=N` 切换：

| N | 算法 | 代码位置 | 说明 |
|---|---|---|---|
| 0 | Park-Miller 全局 RNG | 640–644 | `os::random()`，多核下全局状态缓存一致性开销大 |
| 1 | `地址>>3 ^ stw_random` | 645–650 | STW 之间幂等稳定，可用于 1-0 同步方案 |
| 2 | 恒 1 | 651–652 | 专门做敏感性测试 |
| 3 | 自增序列 | 653–654 | `++GVars.hc_sequence`，顺序可预测 |
| 4 | 对象地址 | 655–656 | `cast_from_oop<intptr_t>(obj)`，最简单 |
| **默认** | **Marsaglia xor-shift** | 657–670 | **线程本地状态 `_hashStateX/Y/Z/W`，无锁无竞争** |

共同收尾（672–674）：

```cpp
value &= markWord::hash_mask;      // 只保留 hash 位
if (value == 0) value = 0xBAD;     // 0 被替换为 0xBAD，与"未生成"哨兵区分
assert(value != markWord::no_hash, "invariant");
```

## 五、对象头：mark word 布局与读取

`src/hotspot/share/oops/markWord.hpp` 关键定义：

- **141**：`hash_shift`（hash 域的起始位）
- **151**：`hash_mask_in_place = right_n_bits(hash_bits) << hash_shift`
- **165**：`hash_mask = hash_mask_in_place >> hash_shift`
- **188**：`no_hash = 0`（"未生成"哨兵）
- **293–298**：读取与判空

```cpp
intptr_t hash() const {                          // 293-294
    return mask_bits(value() >> hash_shift, hash_mask);
}
bool has_no_hash() const {                       // 297-298
    return hash() == no_hash;
}
```

64 位 mark word 简化布局：

```
┌───────────────┬──────────┬──────┬──────┬──────┐
│  unused/bias  │   hash   │ age  │ bias │ lock │
│    高位        │  ~30 bit │ 4bit │ 1bit │ 2bit │
└───────────────┴──────────┴──────┴──────┴──────┘
```

因为 hash 存在这里，`hashCode()` 才有"同一对象只生成一次"的语义。

## 六、JIT intrinsic 路径

- **总开关** `globals.hpp:294`：`product(bool, InlineObjectHash, true, DIAGNOSTIC, ...)`
- **启用检查** `vmIntrinsics.cpp:469`：`if (!InlineObjectHash) return true;`（关闭则退回 JNI）
- **C2 识别** `c2compiler.cpp:620`：`case vmIntrinsics::_hashCode:`
- **分发** `library_call.cpp:252`：`inline_native_hashcode(...)`

流程：方法达到编译阈值 → C2 扫描到 `hashCode()` 调用 → 命中 `_hashCode` intrinsic → 直接内联生成"读 mark word + 生成 + CAS"的机器码，省去 JNI 调用与栈帧开销。

## 七、验证实验

用编译产物 `build\windows-x86_64-server-release\images\jdk\bin\java.exe` 跑：

```bash
java -XX:hashCode=2 YourClass    # 所有对象 hashCode 恒为 1
java -XX:hashCode=4 YourClass    # hashCode = 对象地址
```

写个循环 new 一批对象打 hash 观察规律：

- 默认算法下，相邻对象 hash 完全打散（注释 636 行专门解释为何不用 `obj ^ stw_random`——避免相邻对象 hash 太规律，导致哈希表碰撞集中）。
- `-XX:hashCode=4` 时 hash 与对象地址相关，能直接验证"hash 即地址"。

## 八、全链路图

<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 860 660" role="img" font-family="'Segoe UI', 'Microsoft YaHei', sans-serif">
<title>hashCode 全链路图</title>
<desc>从 Java 层 hashCode 调用到 HotSpot FastHashCode 与 mark word 安装的完整链路</desc>
<defs>
  <marker id="arr" markerWidth="9" markerHeight="9" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 z" fill="#888780"/></marker>
</defs>
<style>
  .card{stroke-width:1.5}
  .t{font-size:15px;font-weight:bold}
  .s{font-size:12.5px;font-family:Consolas,monospace}
  .lab{font-size:12px;fill:#5F5E5A;font-family:Consolas,monospace}
  .arr{stroke:#888780;stroke-width:1.6;fill:none;marker-end:url(#arr)}
</style>
<rect x="230" y="46" width="400" height="58" rx="12" fill="#FAEEDA" stroke="#BA7517" class="card"/>
<text x="430" y="72" text-anchor="middle" fill="#633806" class="t">你的代码：obj.hashCode()</text>
<text x="430" y="92" text-anchor="middle" fill="#854F0B" class="s">Object.java:130-131  native + @IntrinsicCandidate</text>
<line x1="340" y1="104" x2="225" y2="156" class="arr"/>
<line x1="520" y1="104" x2="635" y2="156" class="arr"/>
<rect x="40" y="158" width="370" height="88" rx="12" fill="#E6F1FB" stroke="#185FA5" class="card"/>
<text x="225" y="184" text-anchor="middle" fill="#0C447C" class="t">JNI 路径（解释执行）</text>
<text x="225" y="206" text-anchor="middle" fill="#185FA5" class="s">jvm.cpp:787  JVM_IHashCode</text>
<text x="225" y="228" text-anchor="middle" fill="#185FA5" class="s">jvm.cpp:836  → FastHashCode(THREAD, obj)</text>
<rect x="450" y="158" width="370" height="88" rx="12" fill="#EEEDFE" stroke="#534AB7" class="card"/>
<text x="635" y="184" text-anchor="middle" fill="#3C3489" class="t">JIT intrinsic 路径（编译后）</text>
<text x="635" y="206" text-anchor="middle" fill="#534AB7" class="s">library_call.cpp:252  inline_native_hashcode</text>
<text x="635" y="228" text-anchor="middle" fill="#534AB7" class="s">oop.cpp:118  slow_identity_hash（回退）</text>
<line x1="225" y1="246" x2="320" y2="318" class="arr"/>
<line x1="635" y1="246" x2="540" y2="318" class="arr"/>
<rect x="230" y="320" width="400" height="62" rx="12" fill="#FAEEDA" stroke="#BA7517" stroke-width="2" class="card"/>
<text x="430" y="346" text-anchor="middle" fill="#633806" class="t">ObjectSynchronizer::FastHashCode</text>
<text x="430" y="368" text-anchor="middle" fill="#854F0B" class="s">synchronizer.cpp:678-700</text>
<line x1="430" y1="382" x2="430" y2="440" class="arr"/>
<rect x="110" y="442" width="640" height="104" rx="12" fill="#EAF3DE" stroke="#3B6D11" class="card"/>
<text x="430" y="466" text-anchor="middle" fill="#27500A" class="t">核心流程：读 → 判 → 生成 → CAS 安装</text>
<text x="430" y="490" text-anchor="middle" fill="#3B6D11" class="s">686 mark_acquire 读对象头 → 687 mark.hash()</text>
<text x="430" y="510" text-anchor="middle" fill="#3B6D11" class="s">688 hash != 0 → 直接返回  |  691 get_next_hash 生成</text>
<text x="430" y="530" text-anchor="middle" fill="#3B6D11" class="s">692-694 copy_set_hash + cas_set_mark 原子安装</text>
<line x1="430" y1="546" x2="430" y2="590" class="arr"/>
<rect x="230" y="592" width="400" height="52" rx="12" fill="#C0DD97" stroke="#3B6D11" class="card"/>
<text x="430" y="615" text-anchor="middle" fill="#173404" class="t">hash 已缓存在对象头</text>
<text x="430" y="634" text-anchor="middle" fill="#27500A" class="s">后续 hashCode() 直接 mark.hash() 返回</text>
</svg>

## 附录：一句话索引

| 我想…… | 去哪里 |
|---|---|
| 换一种生成算法 | `synchronizer.cpp:638` + `-XX:hashCode=N` |
| 看 hash 存在哪 | `markWord.hpp:293` + `synchronizer.cpp:686` 注释 |
| 关掉 JIT 内联 | `globals.hpp:294` `InlineObjectHash=false` |
| 下钻线程本地随机状态 | `_hashStateX/Y/Z/W`（synchronizer.cpp:661-669） |
| 看对象头完整布局 | `markWord.hpp`（141-188） |
| 了解 Valhalla inline class 特判 | `jvm.cpp:793-802` |
