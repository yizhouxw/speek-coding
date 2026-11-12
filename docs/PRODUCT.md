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

正式发布应使用固定分发签名身份，让 SpeekCoding 的麦克风、辅助功能和事件发送权限归属于同一个 App。原生输入监控也归属于 SpeekCoding。

## 核心用户旅程

1. 用户安装与 Mac 架构匹配的 `.pkg`；Node.js、Python/faster-whisper 和原生二进制已经包含在 App 中。
2. v0.3.1 起，用户打开 App 后自动准备配置、客户端、HUD 和本地服务；菜单显示准备状态，失败时可点击重试。
3. 用户在系统界面授予 SpeekCoding 麦克风与输入监控权限，需要自动粘贴时再授权辅助功能与模拟按键。
4. 用户在菜单中选择麦克风、准备模型，然后轻按 Fn 或 DJI 按钮开始与停止。
5. 升级后重新打开 App 自动刷新用户配置与辅助程序，无需手动命令。
6. CLI 保留为可选的开发与排障入口。

## 产品原则

- 单一权限主体：麦克风采集、权限检测、剪贴板和 CGEvent 交付全部发生在 `SpeekCoding.app` 进程内。
- 私密默认值：本地端点优先，不静默切换到云服务。
- 安全触发：CLI 使用每用户、带随机 token 的 Unix socket；URL 入口不接受无凭据命令或配置覆盖。
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
| SpeekCoding.app | Microphone、Input Monitoring、Accessibility / Event Posting | HID 设备驱动、ASR 模型托管 |
| ASR LaunchAgent | 无敏感 TCC 权限 | 麦克风、Accessibility、权限检测 |
| CLI | 读取当前用户 IPC token | 直接录音或发送 GUI 事件 |

## 暂不承诺

- Windows 或 Linux 支持
- 无人值守地授予系统隐私权限
- 对所有 HID 麦克风按键的自动识别
- 云端账号、同步、用量统计
- 对第三方远端 ASR 的隐私保证
- 向录音开始后已退出的目标应用自动改投其他窗口
