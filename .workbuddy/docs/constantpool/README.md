# 常量池源码跟读系列

> 起点：`cp_info` —— 类文件里每一条常量项的双字节结构
> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 阅读原则：所有行号均来自本仓库真实源码，可随时在 IDEA 中 `Ctrl+Shift+N` 跳转验证

---

## 为什么读常量池

常量池是类文件三大结构（魔数+版本 / 常量池 / 其余）里唯一**直接决定字节码语义**的表：`new`、`invokevirtual`、`getstatic` 等指令里带的 `#12` 之类索引，全部指向这张表。读懂常量池 = 拿到「字节码 ←→ 运行时常量池 ←→ 真实对象/方法」这条解析链的枢纽。

本系列与[类加载系列](../classload/README.md)互为前后脚：常量池讲「表结构 + 解析」，类加载讲「读表、链接、初始化」的完整流程。

## 系列目录

| 编号 | 主题 | 核心链路 | 配套动画 | 状态 |
|---|---|---|---|---|
| [01](01-classfile-cp.md) | 类文件常量池 `#12` 长什么样 | `cp_info` 双字节表 → 14 种 tag → `Dog` 示例逐项拆解 → `ClassFileParser::parse_constant_pool` 实读 | [🎬](01-classfile-cp-animation.html) | ✅ |
| [02](02-runtime-cp.md) | 运行时常量池与解析 | `ConstantPool` 驻留堆内 → 符号引用 vs 直接引用 → 懒解析（`klass_at_impl` / `resolve_invoke`）→ `ConstantPoolCache` 缓存 → 双胞胎 | [🎬](02-runtime-cp-animation.html) | ✅ |

## 交互动画（自包含 HTML，零外部依赖）

| 动画 | 主题 | 步骤 | 操作 |
|---|---|---|---|
| [01-classfile-cp-animation.html](01-classfile-cp-animation.html) | 类文件常量池 `#12` 逐项拆解 | 15 步 | Space 播放/暂停 · ← → 步进 · R 重置 |
| [02-runtime-cp-animation.html](02-runtime-cp-animation.html) | 懒解析 / 缓存 / 双胞胎 | 15 步 | 同上 |

## 与类加载系列的衔接

- 常量池 01 → 类文件解析入口（`parse_stream` 里 `parse_constant_pool` 那一步）
- 常量池 02 → 类加载 02 的「懒解析不集中解析」、类加载 03 的 `<clinit>` 触发屏障（`klass_at` 解析类引用）

## 待跟进主题（与常量池相关）

- [ ] 字符串常量池（`String.intern()` → `stringTable.cpp`）
- [ ] `invokedynamic` 的 bootstrap 解析（indy 走 `ConstantPoolCache` 的另一半）
