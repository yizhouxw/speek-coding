# 原生输入基础库实验

`NativeInput` 是 Swift Package。当前源码已将 `FnObserver` 静态链接进 App（源码安装和安装包使用同一构建入口），提供默认关闭的实验性原生 Fn 开关；`DJIObserver` 仍未接入产品。已发布的 v0.2.0 不含此功能。执行 `swift test --package-path NativeInput`。部署目标为 macOS 13；在 macOS 27.0.1 Apple Silicon 上编译与测试，**没有在 macOS 13 上运行**。

## 接口与限制

- `DJIObserver` 以 VID 11427/PID 16401 匹配 HID 服务，按 registry entry ID 区分服务，筛选 Consumer page 0x0c、volume increment 0xe9。报告连接、移除和按下/释放；每个服务的重复值被去重，移除时清除状态，不补发释放。一个物理设备可能有多个 HID 服务；ID 不是跨重连的稳定标识。
- `FnObserver` 使用 session listen-only CGEvent tap，Fn 在 1 秒内释放，且没有其他按键、修饰键、系统按键、鼠标点击或滚动时才报告单击。Fn 按下时还检查本轮监听已经观察到、尚未释放的其他按键；启动前已按住但未产生事件的普通键仍无法识别。tap 被禁用、睡眠/唤醒或用户会话切换时清除手势，孤立释放不触发；系统保留组合、硬件差异和丢失事件仍需实测。事件永不被吞掉，Fn 本身的系统行为仍会发生。
- 在主线程启动、停止并持有观察者，回调在主运行循环执行且应快速返回。停止或释放时状态清空。回调不应重入启动/停止或释放观察者。
- `CGPreflightListenEventAccess()` 为 false 时直接返回 `inputMonitoringUnavailable`，不弹授权框；tap 创建和 HID 打开失败也显式返回错误。App 的原生模式通过菜单引导输入监控授权，并定期检查权限与恢复监听；关闭原生模式可恢复已有 Karabiner 路径。授权检查并不能保证设备可打开或事件一定到达；授权撤销和竞争仍需运行时诊断。此包不改变系统权限。

## 屏蔽与共存

IOHIDManager 的 input value callback 用于观察设备值，不提供逐事件吞掉系统输入的返回值。Apple 对 [`kIOHIDOptionsTypeSeizeDevice`](https://developer.apple.com/documentation/iokit/1556660-anonymous/kiohidoptionstypeseizedevice) 的说明是独占该设备并阻止系统和其他客户端接收其事件；这不是只屏蔽 volume increment，可能影响同一 HID 服务上的其他控制，也可能与 Karabiner 或其他独占客户端冲突。不同 USB 接口/服务之间的实际边界须按设备描述符验证，不能推断音频功能一定不受影响。此库没有实现独占。

CGEvent tap 能过滤事件，但公开接口尚未证明能可靠将系统音量事件与特定 HID 设备关联；靠时间相关性猜测设备来源可能误吞其他键盘音量键，不能作为安全替代方案。Apple 的 [HID 回调文档](https://developer.apple.com/documentation/iokit/1438367-iohidmanagerregisterinputvalueca) 和 [事件 tap 概览](https://developer.apple.com/documentation/coregraphics/quartz-event-services) 描述了各自的作用。关于权限和监听范围还应结合 [Apple 开发者论坛讨论](https://developer.apple.com/forums/thread/811443) 在目标版本上验证。

## 尚待验证和迁移

自动测试只验证纯状态机；以下记录了有限的本机实测，不能证明所有硬件、权限状态或屏蔽能力。建议先在备用 Mac/账户和独立签名的测试宿主中，准备备用输入设备及恢复路径，由用户配合验证：设备连接和移除、重复值、不同设备和重连、Fn 单击和各种组合、睡眠恢复、授权拒绝及撤销、Karabiner 共存。对独占测试另行取得用户配合，记录所有同服务功能和其他客户端影响，并验证退出或崩溃后恢复。确认可安全地只处理目标音量事件及回退机制之前，继续使用现有 Karabiner 工作流，避免双重触发。

## 2026-11-03 本机协作实测

在 macOS 27.0.1 Apple Silicon 上，临时签名的测试宿主最初没有 Input Monitoring 权限，两种观察者均按预期返回 `inputMonitoringUnavailable`。用户自行授权后，Fn tap 成功创建；Karabiner 运行时 DJI 打开返回 `kIOReturnExclusiveAccess`。不能单凭此结果断定独占者身份。用户暂时退出 Karabiner 后，非独占 DJI 监听成功，收到了连接事件、两次完整的按下/释放，以及重连后的按下/释放。首次拔插未报告移除：移除时读取 registry ID 失败；改为连接时缓存 ID 后，复测收到了移除、重连和完整按键事件。真实硬件未刻意产生重复输入，去重仍只由单元测试覆盖。

Fn 在两种状态下均未报告单击。附加的只监听 flagsChanged 诊断在 Fn+Shift 时收到了 Shift 变化且标志包含 Fn，但未收到 Fn 自身的 flagsChanged 事件，因此本机尚不能验证 Fn 单击或组合判别。需要进一步调查硬件、系统设置和事件分发，不能把当前实现作为可用替代。测试没有独占设备、屏蔽输入或验证音量屏蔽；macOS 13 和权限撤销仍待实测。测试宿主与正式 App 的签名、权限主体不同。用户可恢复 Karabiner 并自行撤销临时测试宿主的输入监控权限。

## 使用当前源码的原生 Fn 模式

本阶段针对已完成初始配置的 App 用户。CLI 的首次 `speek setup` 仍会准备 Karabiner；完整移除安装依赖和 DJI 按钮替代尚待后续迁移。

1. 更新当前源码构建的 App，在菜单“功能设置”中启用“原生 Fn 触发（实验性）”。
2. 从 Karabiner 菜单选择 **Quit Karabiner-Elements**。仅关闭设置窗口不够。或者自行停用 Fn 重映射规则，并确认单独 Fn 事件能传到系统；这不等同于所有 Karabiner 配置都可共存。
3. 在系统设置 → 隐私与安全性 → 输入监控中允许 **SpeekCoding**。授权测试终端不等于授权 App；必要时重启 App。菜单会显示未监听状态并提供重试。
4. 将系统设置 → 键盘 → 按下 Fn/地球仪键时设为“不执行任何操作”，避免系统输入法/表情面板同时出现。应用不会自动更改这个偏好。
5. 轻按 Fn 开始/结束录音；Fn 组合与超过 1 秒的长按不触发。关闭原生开关后，可重新运行 Karabiner 恢复旧路径。

原生模式启用时，App 忽略托管规则的 `source=fn` 命令，避免双重触发。DJI 命令仍可接收，但退出 Karabiner 后 DJI 按钮尚无产品级替代。监听成功仅代表 event tap 已创建，不保证上游没有吞掉 Fn。

## 可复现诊断

```bash
swift run --package-path NativeInput native-input-diagnose --seconds 30
```

在显示 `READY` 后轻按 Fn 三次，再试 Fn+Shift、Fn+F12 和超过 1 秒的长按，预期输出三次 `FN_TAP`。程序只输出 Fn 状态、手势取消和键盘打开结果，不记录输入文字、其他键码或设备序列号，也不会录音。若 Input Monitoring 为 false，需要为启动它的终端/宿主授权后重试。`exclusive access` 表示物理键盘被另一客户端独占，不能仅凭返回码认定独占者。

## 2026-11-12 排查结果

- 现有 Karabiner Fn 规则使用 `lazy: true` 与 `to_if_alone`：单击只执行命令，Fn 仅在组合键中转发。下游 Quartz 监听不到被规则吞掉的单击属于预期行为；换成 HID 位置的 Quartz tap 也不能绕过该重映射。
- 排查开始时，物理键盘打开返回 `kIOReturnExclusiveAccess`，虚拟键盘可打开；Karabiner 用户服务仍运行。选择 Quit 后，虚拟键盘消失、物理键盘打开成功，原有 session tap 收到 Fn 事件并报告单击。系统级 Karabiner 服务仍留驻，因此不能只用“是否存在任何 Karabiner 进程”判断键盘是否已释放。
- 本次无法重现此前“退出后仍没有 Fn flagsChanged”的现象，历史原因未完全证实。第一轮混合动作有多余回调；随后定向测试 Fn+F12 收到正常的 keyDown/keyUp，未证实它是多余回调来源。
- 使用 Quartz `keyState` 检查预按键时，退出重映射工具后 HID/session 两张状态表都残留了 Delete 按下状态，导致正常 Fn 被拒绝。因此预按键检查改为维护当前监听收到的 keyDown/keyUp，不依赖该全局状态表；重置时清空。
- 修正后的独立诊断在 Karabiner 退出、物理键盘打开成功时完成实测：3 次轻按输出恰好 3 次 `FN_TAP`，Fn+Shift、Fn+F12 和超过 1 秒的长按均未增加回调，最终 `DONE taps=3`。
- 回归测试覆盖单击、重复释放、其他键/系统按键/鼠标取消、预先按住其他键、长按、tap 禁用、状态重置。补充了 `systemDefined` 监听以覆盖媒体键路径，依据 [Apple 的系统事件定义](https://developer.apple.com/documentation/appkit/nsevent/eventtype/systemdefined)。

尚待验证：正式 App 权限主体下的端到端录音、macOS 13/14、外接键盘、权限撤销、睡眠/唤醒及系统保留组合。独立诊断实测不等于上述场景全部通过。下一阶段需完成原生安装流程和 DJI 设备级事件处理，才能宣称整个 App 不依赖 Karabiner。

## DJI UserKeyMapping：自动验证阶段

`DJIMapping` 是无副作用的映射规划层，尚未写入真实设备。仅接受 USB、VID 11427/PID 16401、Consumer Control 0x0c/0x01 且有有效 registry ID 的服务；仅添加 `0x0000000c000000e9 → 0`。其他映射按原顺序保留。遇到用户已有的不同目标映射或重复源条目时拒绝接管。

恢复计划绑定原 registry ID，且仅在当前映射仍与安装结果完全一致时才返回原值；用户本来已有的屏蔽映射不由应用删除。实际属性写入仍需要串行化、写后读取校验及处理外部修改竞争，这个纯规划层不提供系统级原子保证。

自动测试覆盖非 DJI 设备、键盘/鼠标服务排除、其他音量键映射保留、用户配置冲突、重连接口身份变化与退出恢复所有权。它们只证明规划规则，不证明系统已屏蔽事件，也不证明音频输入或热插拔行为已经实测通过。后续需将按服务属性适配器与原始 HID 监听组合，只有映射确认成功才进入就绪状态；不能以全局 UserKeyMapping 写入替代服务级操作。
