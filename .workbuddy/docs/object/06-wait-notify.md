# wait() / notify() / notifyAll()：监视器 Monitor 的入口

> 版本：JDK 28 主线（`D:\project\jdk`，`28-internal`）
> 系列：Object 源码跟读 · 第 06 篇（[回到系列索引](README.md)）
> 主题：`synchronized` 的底层 Monitor 机制——wait/notify 如何从 Java 一路走到 `ObjectMonitor`

---

## 快速概览

- **一句话结论**：`wait`/`notify`/`notifyAll` 是 **Monitor（监视器）** 的 Java 门面。它们的 native 实现（`wait0`/`notify`/`notifyAll`）由 VM 静态注册到 `JVM_MonitorWait`/`JVM_MonitorNotify`/`JVM_MonitorNotifyAll`，核心动作是**把锁"膨胀"成重量级 `ObjectMonitor`**，然后对等待队列（ObjectWaiter）做挂起/唤醒。
- **JDK 28 改名**：真正 native 的方法叫 **`wait0`**（`vmSymbols.hpp:462` 的 `wait_name` 就是 `"wait0"`），Java 层 `wait()`/`wait(long)` 是包装，且 `wait(long)` 里有**虚拟线程分支**（458–465 行）。
- **阅读顺序建议**：`Object.java`（三个 wait + wait0）→ `javaClasses.cpp`（绑定）→ `jvm.cpp:841` → `synchronizer.cpp`（重点）→ `objectMonitor.cpp`（下钻）。

### 配套交互动画

▶ ** [06-wait-notify-monitor-animation.html](06-wait-notify-monitor-animation.html)** —— 锁膨胀 + ObjectMonitor 队列流转 12 步动画：
T1 `wait` 触发膨胀（fast-locked → monitor）→ 挂入 `_WaitSet` → T2 `notify` 从 `_WaitSet` 摘 waiter 转入 `_EntryList` → T1 重新持锁。含 Owner / cxq / EntryList / WaitSet 四区实时状态与真实源码面板。

### 核心文件索引

| 文件 | 关键行 | 内容 |
|---|---|---|
| `src/java.base/share/classes/java/lang/Object.java` | 419–472 | `wait()`/`wait(long)`/`wait0`（虚拟线程分支） |
| `src/java.base/share/classes/java/lang/Object.java` | 577–592 | `wait(long,int)` 参数校验与进位 |
| `src/hotspot/share/classfile/vmSymbols.hpp` | 462 | **`wait_name` = `"wait0"`**（改名真相） |
| `src/hotspot/share/classfile/javaClasses.cpp` | 96–101 | 绑定：`wait0/notify/notifyAll` → `JVM_*` |
| `src/hotspot/share/prims/jvm.cpp` | 841 / 847 / 853 | `JVM_MonitorWait` / `JVM_MonitorNotify` / `JVM_MonitorNotifyAll` |
| `src/hotspot/share/runtime/synchronizer.cpp` | 547 / 577 / 591 | `ObjectSynchronizer::wait/notify/notifyall`（本篇重点） |
| `src/hotspot/share/runtime/objectMonitor.cpp` | 1657 / 2032 / 2060 | `ObjectMonitor::wait/notify/notifyAll`（下钻入口） |

---

## 一、Java 层：三个 wait 重载的真相

JDK 28 的 `Object.java` 里 wait 家族共 **4 个方法、只有 1 个 native**：

### 1.1 wait() — 纯包装（419–421）

```java
public final void wait() throws InterruptedException {
    wait(0L);
}
```

### 1.2 wait(long) — 虚拟线程分支（453–469）

```java
public final void wait(long timeoutMillis) throws InterruptedException {
    if (timeoutMillis < 0) {
        throw new IllegalArgumentException("timeout value is negative");
    }
    if (Thread.currentThread() instanceof VirtualThread vthread) {
        try {
            wait0(timeoutMillis);
        } catch (InterruptedException e) {
            // virtual thread's interrupted status needs to be cleared
            vthread.getAndClearInterrupt();
            throw e;
        }
    } else {
        wait0(timeoutMillis);
    }
}
```

**JDK 21+（虚拟线程）的痕迹**：虚拟线程阻塞时不能占住平台线程，且中断语义要特殊处理（462–464 行：虚拟线程的 interrupted status 需要单独清除，因为它的中断可能发生在不同载体上）。`instanceof VirtualThread` 模式匹配直接决定了调用路径。

### 1.3 wait0(long) — 唯一的 native（471–472）

```java
// final modifier so method not in vtable
private final native void wait0(long timeoutMillis) throws InterruptedException;
```

471 行注释是精华：**`final` 是为了不让它进虚表（vtable）**——wait 语义必须绝对统一，禁止任何子类"插队"。

### 1.4 wait(long, int) — 参数校验与进位（577–592）

```java
if (nanos < 0 || nanos > 999999) { throw new IllegalArgumentException(...); }
if (nanos > 0 && timeoutMillis < Long.MAX_VALUE) {
    timeoutMillis++;          // nanos 向上取整进位
}
wait(timeoutMillis);
```

注意 587–589 行的**进位**：`wait(0, 500)` 会变成 `wait(1)`——JVM 只按毫秒精度挂起，纳秒余量向上取整（保证"至少等够"语义）。

## 二、绑定：wait0 的改名故事

注册表 `javaClasses.cpp:96-101`：

```cpp
Method::register_native(obj, vmSymbols::wait_name(),     // "wait0"！
                        vmSymbols::long_void_signature(), (address) &JVM_MonitorWait, CHECK);
Method::register_native(obj, vmSymbols::notify_name(),
                        vmSymbols::void_method_signature(), (address) &JVM_MonitorNotify, CHECK);
Method::register_native(obj, vmSymbols::notifyAll_name(),
                        vmSymbols::void_method_signature(), (address) &JVM_MonitorNotifyAll, CHECK);
```

关键在 `vmSymbols.hpp:462`：

```cpp
template(wait_name, "wait0")
```

**`wait_name` 符号的值就是 `"wait0"`**——因为 Java 侧 native 方法改名了，hotspot 符号表同步改名，注册按名字+签名 `wait0(J)V` 精确命中。这就是为什么 grep hotspot 里搜 `"wait"` 找不到 `JVM_MonitorWait` 的注册入口（名字对不上）。

## 三、JVM 入口：三个薄壳

`jvm.cpp:841-856`——三兄弟结构完全一致，只做一件事：**把 JNI 句柄解析成 oop，转发给 ObjectSynchronizer**：

```cpp
JVM_ENTRY(void, JVM_MonitorWait(JNIEnv* env, jobject handle, jlong ms))
  Handle obj(THREAD, JNIHandles::resolve_non_null(handle));
  ObjectSynchronizer::wait(obj, ms, CHECK);
JVM_END

JVM_ENTRY(void, JVM_MonitorNotify(JNIEnv* env, jobject handle))
  Handle obj(THREAD, JNIHandles::resolve_non_null(handle));
  ObjectSynchronizer::notify(obj, CHECK);
JVM_END
```

## 四、核心：ObjectSynchronizer（本篇重点）

### 4.1 wait — 锁膨胀 + 挂起（synchronizer.cpp:547-566）

```cpp
// NOTE: must use heavy weight monitor to handle wait()
int ObjectSynchronizer::wait(Handle obj, jlong millis, TRAPS) {
  JavaThread* current = THREAD;
  CHECK_THROW_NOSYNC_IMSE_0(obj);          // ① 非 owner → IllegalMonitorStateException
  if (millis < 0) {
    THROW_MSG_0(vmSymbols::java_lang_IllegalArgumentException(), "timeout value is negative");
  }
  ObjectMonitor* monitor;
  monitor = ObjectSynchronizer::inflate_locked_or_imse(obj(), inflate_cause_wait, CHECK_0);  // ② 膨胀
  monitor->wait(millis, true, THREAD);     // ③ 挂起（objectMonitor.cpp:1657）
  ...
}
```

**第一步注释就把原理说破了**："must use heavy weight monitor to handle wait()"——**只有重量级锁（ObjectMonitor）才有等待队列**。偏向锁/轻量锁的 mark word 里没有挂起线程的地方，所以 wait 强制触发**锁膨胀**（inflate）。

`inflate_locked_or_imse` 内部：检查当前线程确实是 owner（否则抛 `IllegalMonitorStateException`，这就是 345–346 行 javadoc 说的"wait 必须持有 monitor"），然后把对象头换成指向 `ObjectMonitor` 的指针。

### 4.2 notify / notifyAll — 未膨胀就无事可做（577-603）

```cpp
void ObjectSynchronizer::notify(Handle obj, TRAPS) {
  JavaThread* current = THREAD;
  CHECK_THROW_NOSYNC_IMSE(obj);

  markWord mark = obj->mark();
  if ((mark.is_fast_locked() && current->lock_stack().contains(obj()))) {
    // Not inflated so there can't be any waiters to notify.
    return;                                    // ① 快速路径：还是轻量锁 → 肯定没 waiter
  }
  ObjectMonitor* monitor = ObjectSynchronizer::inflate_locked_or_imse(obj(), inflate_cause_notify, CHECK);
  monitor->notify(CHECK);                      // ② objectMonitor.cpp:2032
}
```

582–585 行的**快速路径优化**很妙：如果对象还是**快速锁**（fast-locked，即轻量锁状态）且当前线程持有它，那**必然没有等待者**（有 wait 早就膨胀了）——直接返回，省掉一次膨胀。`notifyAll` 结构完全一样（591–603）。

## 五、下钻入口：ObjectMonitor

`monitor->wait(millis, true, THREAD)` 进入 `objectMonitor.cpp:1657`，这里开始接触等待队列：

- `ObjectMonitor::wait`（1657）：把当前线程包成 **`ObjectWaiter`** 挂进 `_WaitSet` 链表，释放 monitor（`exit(true)`），然后 `park` 挂起；被唤醒后重新竞争锁（`enter`）。
- `ObjectMonitor::notify`（2032）：从 `_WaitSet` 摘一个 waiter 转进 `_EntryList`（竞争锁的队列）。
- `ObjectMonitor::notifyAll`（2060）：清空 `_WaitSet` 全部转入 `_EntryList`。

这是整个 synchronized 机制最深的一层，系列 README 已登记为待跟进主题。

## 六、验证实验

```java
public class W {
    static final Object LOCK = new Object();
    public static void main(String[] a) throws Exception {
        Thread t = new Thread(() -> {
            synchronized (LOCK) {
                try { LOCK.wait(500); } catch (InterruptedException e) { }
                System.out.println("woke up");
            }
        });
        t.start();
        Thread.sleep(100);
        synchronized (LOCK) { LOCK.notify(); }   // 提前唤醒
        t.join();
    }
}
```

观察：输出 `woke up` 且提前（未到 500ms）——证明 notify 从等待队列里把线程唤醒了。可加 `-Xlog:monitorinflation` 看锁膨胀日志：

```bash
D:\project\jdk\build\windows-x86_64-server-release\images\jdk\bin\java.exe -Xlog:monitorinflation W
```

## 附录：一句话索引

| 我想…… | 去哪里 |
|---|---|
| 看 wait 的 native 绑定名 | `vmSymbols.hpp:462`（`"wait0"`） |
| 看 Java 层虚拟线程分支 | `Object.java:458-465` |
| 看 wait 强制膨胀的注释 | `synchronizer.cpp:545` |
| 看 notify 的快速路径 | `synchronizer.cpp:582-585` |
| 下钻等待队列 | `objectMonitor.cpp:1657`（wait）/ 2032（notify）/ 2060（notifyAll） |
