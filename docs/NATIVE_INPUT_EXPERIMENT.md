# 原生输入基础库实验

`NativeInput` 是独立的 Swift Package，尚未接入 App、安装包或 Karabiner 规则。执行 `swift test --package-path NativeInput`。目标部署版本为 macOS 13，与现有产品一致；本次在 macOS 27.0.1、Apple Silicon、Xcode 27.2 以 macOS 13 部署目标编译并通过状态机测试，**没有在 macOS 13 上运行**。

## 接口与限制

- `DJIObserver` 以 VID 11427/PID 16401 匹配 HID 服务，按 registry entry ID 区分服务，筛选 Consumer page 0x0c、volume increment 0xe9。报告连接、移除和按下/释放；每个服务的重复值被去重，移除时清除状态，不补发释放。一个物理设备可能有多个 HID 服务；ID 不是跨重连的稳定标识。
- `FnObserver` 使用 session listen-only CGEvent tap，Fn 释放时只有期间没有其他键或修饰键变化才报告单击。启动时已按住的键、Fn 硬件/系统设置、系统保留组合、睡眠和事件丢失可能影响判断；tap 被禁用时状态重置并尝试恢复。事件永不被吞掉，Fn 本身的系统行为仍会发生。
- 在主线程启动、停止并持有观察者，回调在主运行循环执行且应快速返回。停止或释放时状态清空。回调不应重入启动/停止或释放观察者。
- `CGPreflightListenEventAccess()` 为 false 时直接返回 `inputMonitoringUnavailable`，不弹授权框；tap 创建和 HID 打开失败也显式返回错误。宿主应保留现有 Karabiner 路径，并在适当的用户操作中解释和引导授权，再重新创建监听。授权检查并不能保证设备可打开或事件一定到达；授权撤销和竞争仍需运行时诊断。此包不改变系统权限。

## 屏蔽与共存

IOHIDManager 的 input value callback 用于观察设备值，不提供逐事件吞掉系统输入的返回值。Apple 对 [`kIOHIDOptionsTypeSeizeDevice`](https://developer.apple.com/documentation/iokit/1556660-anonymous/kiohidoptionstypeseizedevice) 的说明是独占该设备并阻止系统和其他客户端接收其事件；这不是只屏蔽 volume increment，可能影响同一 HID 服务上的其他控制，也可能与 Karabiner 或其他独占客户端冲突。不同 USB 接口/服务之间的实际边界须按设备描述符验证，不能推断音频功能一定不受影响。此库没有实现独占。

CGEvent tap 能过滤事件，但公开接口尚未证明能可靠将系统音量事件与特定 HID 设备关联；靠时间相关性猜测设备来源可能误吞其他键盘音量键，不能作为安全替代方案。Apple 的 [HID 回调文档](https://developer.apple.com/documentation/iokit/1438367-iohidmanagerregisterinputvalueca) 和 [事件 tap 概览](https://developer.apple.com/documentation/coregraphics/quartz-event-services) 描述了各自的作用。关于权限和监听范围还应结合 [Apple 开发者论坛讨论](https://developer.apple.com/forums/thread/811443) 在目标版本上验证。

## 尚待验证和迁移

自动测试只验证纯状态机；以下记录了有限的本机实测，不能证明所有硬件、权限状态或屏蔽能力。建议先在备用 Mac/账户和独立签名的测试宿主中，准备备用输入设备及恢复路径，由用户配合验证：设备连接和移除、重复值、不同设备和重连、Fn 单击和各种组合、睡眠恢复、授权拒绝及撤销、Karabiner 共存。对独占测试另行取得用户配合，记录所有同服务功能和其他客户端影响，并验证退出或崩溃后恢复。确认可安全地只处理目标音量事件及回退机制之前，继续使用现有 Karabiner 工作流，避免双重触发。

## 2026-11-03 本机协作实测

在 macOS 27.0.1 Apple Silicon 上，临时签名的测试宿主最初没有 Input Monitoring 权限，两种观察者均按预期返回 `inputMonitoringUnavailable`。用户自行授权后，Fn tap 成功创建；Karabiner 运行时 DJI 打开返回 `kIOReturnExclusiveAccess`。不能单凭此结果断定独占者身份。用户暂时退出 Karabiner 后，非独占 DJI 监听成功，收到了连接事件、两次完整的按下/释放，以及重连后的按下/释放。首次拔插未报告移除：移除时读取 registry ID 失败；改为连接时缓存 ID 后，复测收到了移除、重连和完整按键事件。真实硬件未刻意产生重复输入，去重仍只由单元测试覆盖。

Fn 在两种状态下均未报告单击。附加的只监听 flagsChanged 诊断在 Fn+Shift 时收到了 Shift 变化且标志包含 Fn，但未收到 Fn 自身的 flagsChanged 事件，因此本机尚不能验证 Fn 单击或组合判别。需要进一步调查硬件、系统设置和事件分发，不能把当前实现作为可用替代。测试没有独占设备、屏蔽输入或验证音量屏蔽；macOS 13 和权限撤销仍待实测。测试宿主与正式 App 的签名、权限主体不同。用户可恢复 Karabiner 并自行撤销临时测试宿主的输入监控权限。
