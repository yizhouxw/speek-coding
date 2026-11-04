# SpeekCoding 产品定义

## 一句话定位

SpeekCoding 是给 macOS 开发者使用的本地优先、全局可用的对讲式代码听写 App。

## 产品身份

用户、macOS 权限系统和运行时看到的是同一个产品：

- App 名：`SpeekCoding`
- App 路径：`/Applications/SpeekCoding.app`
- Bundle ID：`com.speek.coding`
- CLI：`speek`（`speek-coding` 为兼容命令名）
- URL Scheme：`speekcoding://`（token-protected 可选入口）

正式发布应使用固定分发签名身份，让 SpeekCoding 的麦克风、辅助功能和事件发送权限归属于同一个 App。Karabiner-Elements 是独立应用，其系统授权另行管理。

## 核心用户旅程

1. 用户安装与 Mac 架构匹配的 `.pkg`；Node.js、Python/faster-whisper 和原生二进制已经包含在 App 中。
2. 用户打开 SpeekCoding，安装并打开 Karabiner-Elements；缺少 Karabiner 时可通过菜单栏下载官方安装包。
3. 用户运行 `speek setup`，选择键盘或 DJI Mic Mini 触发方式，配置鉴权 IPC、Karabiner 规则和本地 ASR 后台服务；分别按 SpeekCoding 和 Karabiner 的提示完成各自的系统授权。
4. 用户在任何支持粘贴的 IDE 或终端按一次触发键。App 记住当前前台进程，开始原生录音，HUD 提供即时反馈。
5. 用户再次按键。App 停止录音、向 ASR 请求转写，并按配置把文字定向粘贴或发送到开始录音时的目标应用。
6. 用户可在菜单栏切换麦克风、查看和处理权限、打开 Karabiner 设置或退出。出现问题时，`speek status` 给出当前状态和优先动作；`speek doctor` 提供 App、签名、IPC、权限、Karabiner 和 ASR 的完整细节。

## 产品原则

- 单一权限主体：麦克风采集、权限检测、剪贴板和 CGEvent 交付全部发生在 `SpeekCoding.app` 进程内。
- 私密默认值：本地端点优先，不静默切换到云服务。
- 安全触发：CLI 和 Karabiner 复用每用户、带随机 token 的 Unix socket；URL 入口不接受无凭据命令或配置覆盖。
- 一次设置：日常使用不依赖常驻终端窗口；App 可由运行时命令按需启动。
- 稳定升级：正式发布应保持 Bundle ID 与 Developer ID 签名身份；源码安装检查身份变化，发布包的签名及升级由发布和安装流程负责。
- 零开发工具依赖：最终用户不需要 Node.js、Python、Homebrew 或 Xcode Command Line Tools；这些只属于发布构建环境。
- 可撤销：ASR 服务可随时停止，所有托管运行时内容可由 `uninstall` 清理。
- 渐进披露：常用命令保持简短，高级 ASR 参数仍可配置。
- 故障透明：触发、录音、转写、权限和交付是独立可观测阶段。

## 当前支持范围

| 能力 | 支持情况 |
| --- | --- |
| 操作系统 | macOS 13 或更高版本 |
| 触发器 | 键盘 Fn、DJI Mic Mini 连接键、`speek trigger` |
| 输入目标 | 录音开始时的前台 macOS 应用；目标需接受剪贴板粘贴 |
| 麦克风运行时 | App 内 AVAudioEngine / CoreAudio |
| 本地 ASR | faster-whisper、whisper.cpp |
| 外部 ASR | OpenAI-compatible transcription endpoint |
| 交付方式 | 粘贴并发送、只粘贴、只复制 |
| 状态反馈 | 菜单栏、缺口硬件自适应原生 HUD、`speek status`、`speek doctor` |

## 权限边界

| 组件 | 需要的权限 | 不负责的能力 |
| --- | --- | --- |
| SpeekCoding.app | Microphone、Accessibility / Event Posting | HID 设备驱动、ASR 模型托管 |
| Karabiner-Elements | 按其引导授予 Input Monitoring、辅助功能及其他所需系统权限 | SpeekCoding 的录音、转写和文字交付 |
| ASR LaunchAgent | 无敏感 TCC 权限 | 麦克风、Accessibility、权限检测 |
| CLI | 读取当前用户 IPC token | 直接录音或发送 GUI 事件 |

## 暂不承诺

- Windows 或 Linux 支持
- 无人值守地完成 Karabiner-Elements 系统扩展安装和隐私授权
- 对所有 HID 麦克风按键的自动识别
- 云端账号、同步、用量统计
- 对第三方远端 ASR 的隐私保证
- 向录音开始后已退出的目标应用自动改投其他窗口
