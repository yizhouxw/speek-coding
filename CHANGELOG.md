# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

- 修复 Fn 触发规则，保留 Fn+F12 等组合键的系统行为。
- 菜单栏增加“功能设置”分类，并说明自动发送会在粘贴时附加回车。
- 纳入独立 NativeInput 原生输入实验库及测试，尚未接入 App 的录音触发路径。
- 以当前代码快照重新建立仓库历史，完善中英文入门、贡献、安全报告与开源维护文档。早期标签和开发预发布包已撤下，以下版本条目仅保留功能变更记录。

## [0.5.3] - 2026-11-04

- 菜单栏新增“自动发送”选项，默认粘贴后按回车；取消勾选后只粘贴转写文字。
- 改进录音悬浮窗的取消操作与生命周期管理。
- 整理产品功能和开发文档。

## [0.5.2] - 2026-11-03

- 菜单栏增加麦克风及自动粘贴权限状态、授权入口和 Karabiner-Elements 安装引导。
- 启动 App 时尝试启动已配置的本地转写服务，正常退出时停止该服务。
- 为 App 增加图标；防止内置 Python 写入字节码破坏签名，并在可用时复用本机开发签名身份。
- 更新安装、使用、故障排查和开发文档。

## [0.5.1] - 2026-11-03

- 更新 Python 依赖，修复发布审计发现的安全漏洞。
- 增加菜单栏麦克风选择与专属图标，首次转写时显示模型下载状态并支持取消。
- 增加双架构开发安装包的 GitHub Actions 预发布流程。

## [0.5.0] - 2026-11-03

- 增加 GitHub Actions 发布流水线，验证双架构开发安装包后创建私有预发布。
- 菜单栏使用结合代码括号与声波的 SpeekCoding 专属图标。
- 增加 macOS 菜单栏入口，可查看和选择麦克风输入设备。
- 首次转写时显示本地模型下载和加载状态；等待期间再次按触发键可取消转写及正在进行的模型下载。

### 其他变更

### Added

- 新增公开贡献行为准则、发布检查清单和 macOS CI，覆盖测试、生命周期烟测与 Node/Python 依赖审计。
- 新增本地 ASR 请求大小、字段长度、loopback 绑定和固定模型保护测试。

### Changed

- 配置、安装清单、日志目录和 LaunchAgent 文件改为私有权限；Karabiner 配置改为原子写入。
- Python 打包依赖改用带 SHA-256 的通用锁文件，Node CLI 依赖升级到 `@clack/prompts` 1.x。
- 远程 ASR endpoint 现在必须使用 HTTPS，明文 HTTP 只允许 loopback 地址。
- 默认 ASR beam size 从 1 调整为 3，在 Apple M4 Pro 实测中没有可感知的额外时延。

### Removed

- 移除未使用且没有明确运行时用途的 `sounds/ready.wav` 二进制资产。

## [0.4.0] - 2026-07-10

### Added

- 新增自包含 macOS `.pkg` 构建：App 内置固定 Node.js、可重定位 Python 和 faster-whisper，并安装 `/usr/local/bin/speek` launcher。
- 新增 arm64 / x86_64 原生构建、下载校验、Developer ID 签名、公证和包展开验证流程。

### Changed

- HUD 现在会识别 MacBook 顶部摄像头缺口并贴合物理屏幕顶边、围绕硬件区域布局；无缺口屏幕继续使用原有顶部悬浮胶囊。
- 最终用户安装不再需要 Node.js、Python、Homebrew 或 Xcode Command Line Tools；`speek setup` 复用包内预编译 App/HUD 和 ASR 运行时。
- `speek uninstall` 在包安装模式下只清理当前用户状态，不删除系统安装器管理的 App 和 CLI launcher。

## [0.3.0] - 2026-07-10

### Added

- 新增真实编译的原生 `SpeekCoding.app`；`CFBundleDisplayName`、App 名与可执行文件统一为 `SpeekCoding`，Bundle ID 固定为 `com.speek.coding`。
- 新增持久本机代码签名身份、hardened runtime、签名验证与 designated requirement 记录，升级时拒绝静默切换身份。
- 新增每用户 Unix socket IPC 和 `0600` 随机 token 鉴权；CLI 会校验 IPC 对端的 Bundle ID 与协议版本。
- 新增 token-protected `speekcoding://` URL Scheme 作为可选入口，只允许 `toggle` / `cancel`。
- 新增原生 AVAudioEngine / CoreAudio 录音、URLSession ASR 请求、NSPasteboard 交付和 `CGEvent.postToPid` 定向发送。
- 新增 App 内 Microphone、Accessibility 和 Event Posting 权限检测与请求。

### Changed

- Karabiner 只负责把 Fn/DJI 事件交给最小化的 `speek-command` 鉴权 IPC 客户端，不再承载录音、转写或事件注入逻辑。
- CLI 的触发、取消、权限检查和录音测试全部改为调用 App IPC。
- App 在录音开始时锁定前台应用 PID，转写完成后将粘贴和可选 Return 定向发送给该进程。
- 本地 ASR LaunchAgent 收口为无敏感 TCC 权限的 HTTP 转写服务；麦克风、Accessibility、CGEvent 和权限检查全部由 App 承担。
- 运行状态目录改为每用户 `/tmp/speek-coding-<uid>/`，socket 与状态不再在不同用户间共享路径。

### Fixed

- 修复升级后绝对路径形式的旧 Karabiner Fn 规则未被清理、抢先吞掉新 IPC 触发的问题。
- 修复 whisper.cpp 在未指定语言时默认偏向英文的问题；`--asr-language auto` 现在对本地后端使用自动检测，并对外部 API 省略固定语言码。

### Removed

- 移除旧录音辅助 App、Python 音频 helper、Shell 状态机和 GUI 脚本运行时；安装器只保留旧路径识别以完成迁移清理。
- 移除运行时对 Python `sounddevice`、PortAudio 和 GUI 脚本的依赖。

## [0.2.0] - 2026-07-10

### Added

- 新增 `setup` 一站式设置命令。
- 新增 macOS LaunchAgent 后台 ASR 服务。
- 新增 `status`、`start`、`stop`、`restart` 和 `logs` 产品命令。
- 新增 ASR 服务配置持久化、健康探测和单元测试。
- 新增产品定义、架构、贡献和安全文档。

### Changed

- 主命令简化为 `speek`，保留 `speek-coding` 兼容别名。
- 配置变量统一为 `SPEEK_*`，并兼容读取旧 `DJI_*` 配置。
- 卸载会清理后台服务、日志和 Python venv。

## [0.1.0]

- 初始本地录音、HUD、Karabiner 触发和 OpenAI-compatible ASR 工作流。
