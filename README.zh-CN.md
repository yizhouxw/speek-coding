# SpeekCoding

[English](README.md) · 简体中文

**把下一条编程指令说出来，直接送进你的编辑器。**

SpeekCoding 是 macOS 上的本地语音输入工具。在 Codex、Claude Code、Cursor、终端或其他应用中，点进输入框，**按一下 Fn 开始说话，再按一下结束**。转写文字会复制到剪贴板，并按你的设置粘贴或发送到开始录音时的应用。

[下载 macOS 安装包](https://github.com/yizhouxw/speek-coding/releases/latest) · [快速开始](#快速开始) · [使用指南](docs/USAGE.zh-CN.md) · [帮助与反馈](SUPPORT.md)

## 为什么用 SpeekCoding

- **边说边出字，减少说完后的等待。** Apple Silicon 上支持实时转写，悬浮窗持续显示草稿，并随着上下文更新修正。结束录音后定稿，转写过程在说话时就已开始。
- **本地智能纠错。** Apple Silicon 的本地 Qwen 引擎可使用小型 Chat 模型理解上下文，整理停顿、断句和识别错误。在“功能设置 → 智能纠错”中开关；“模型管理”分别下载、选择语音识别与文本生成模型。
- **语音留在本机。** 默认使用本地模型，无需 ASR API Key 或云端转写订阅；模型下载完成后，本地转写可离线使用。
- **融入已有工具。** 口述编程需求、描述 Bug、回复消息，在支持粘贴的输入框中使用。可选粘贴并发送、只粘贴或仅复制到剪贴板。
- Fn 与 DJI 按钮使用 App 原生监听，无需安装 Karabiner。请授予 SpeekCoding 输入监控权限；自动粘贴还需辅助功能权限。
- **适配 Apple Silicon，也支持 Intel。** Apple Silicon 使用 Qwen3-ASR-0.6B 的 4-bit 权重与 MLX 加速；Intel 使用本地 faster-whisper，结束录音后转写。
- **原生菜单栏体验。** 麦克风选择、录音反馈、取消操作，以及简体中文、繁體中文和英语界面。安装包自带运行时，用户无需安装 Node.js、Python、Homebrew 或 Xcode。

## 快速开始

**准备条件：** Apple Silicon 需要 macOS 14+，Intel 需要 macOS 13+；准备麦克风并授予 SpeekCoding 输入监控权限。

1. **安装应用。** 从 [Releases](https://github.com/yizhouxw/speek-coding/releases/latest) 下载匹配的 `.pkg`：Apple Silicon 选 `arm64`，Intel 选 `x86_64`。安装后，从“应用程序”打开 **SpeekCoding**。
2. **设置原生触发。** 授予 SpeekCoding 输入监控权限，将 macOS Fn/地球仪操作设为“不执行任何操作”；退出可能占用输入设备的其他映射工具。
3. **完成首次设置。** 打开终端，运行：

   ```bash
   speek setup --trigger-mode keyboard
   speek doctor
   ```

4. **选择麦克风并授权。** 在菜单栏选择麦克风，允许 SpeekCoding 使用麦克风；自动粘贴和发送还需要辅助功能与模拟按键权限。
5. **开始说话。** 点进目标输入框，**按 Fn → 说话 → 再按 Fn**。首次使用需下载并加载模型，后续复用已缓存的权重。

> 当前带 `-dev-` 的安装包未经过 Developer ID 签名或公证，macOS 可能阻止安装或启动，请先阅读对应发布说明。模型权重单独下载。

## 按你的习惯使用

**先检查，再发送。** 默认自动粘贴并按 Return。在“功能设置”中取消勾选“自动发送”，即可只粘贴、不发送；也可通过命令选择：

```bash
speek config --delivery-mode paste_only      # 只粘贴
speek config --delivery-mode clipboard_only  # 只复制
speek config --delivery-mode paste_and_send  # 粘贴并发送（默认）
```

**用无线按钮控制。** 连接 DJI Mic Mini 接收器后，配置发射器按钮：

```bash
speek setup --trigger-mode keyboard+dji --input-device "DJI Mic Mini"
```

**切换麦克风和界面语言。** 直接在菜单栏选择；界面默认跟随 macOS，也可在“功能设置 → 语言”中手动切换。界面语言不影响语音识别语言。

**随时取消。** 点击录音悬浮窗中的 Cancel，或运行 `speek cancel`。转写或模型准备期间再次按 Fn 也可取消；录音期间按 Fn 则表示停止并定稿。

**智能纠错与模型管理。** 先从“功能设置 → 模型管理 → 文本生成模型”下载模型，再点击选择。默认使用 Qwen3-4B-Instruct-2507 4-bit，也提供更轻量的 0.6B / 1.7B。语音识别提供 Qwen3-ASR 0.6B / 1.7B。关闭“智能纠错”即可直接使用原始转写，也可运行 `speek config --transcript-cleanup off`。模型下载后可离线运行；纠错失败时仅复制原文，不自动发送。

## 本地转写

Apple Silicon 新安装默认采用 **Qwen3-ASR-0.6B 4-bit / MLX**，支持实时草稿和识别修正。停止后的定稿仍需计算，耗时取决于机器和录音长度。Intel 默认采用 **faster-whisper**。也可配置本地 Whisper、whisper.cpp 或兼容 OpenAI 文件转写接口的服务。

已有安装会保留原转写引擎。在 Apple Silicon 上更新应用后，可这样切换到 Qwen / MLX：

```bash
speek config --asr-backend qwen-mlx --asr-model mlx-community/Qwen3-ASR-0.6B-4bit
speek asr-install
speek restart
```

引擎选项、设备设置、发送策略及完整命令见[使用指南](docs/USAGE.zh-CN.md)。查看状态用 `speek status`，排查安装问题用 `speek doctor`。`speek update` 刷新当前 CLI 版本对应的本机集成；升级发布版本需下载新的安装包。

## 隐私

默认转写请求仅访问本机服务；首次下载模型 需要联网。没有内置使用行为分析或录音上传服务。主动配置远程 ASR 后，音频会发送到你指定的服务。

普通会话结束后清理临时录音；明确保存的测试录音、模型缓存和剪贴板内容会保留。更多说明见[安全策略](SECURITY.md)。

## 文档与开发

- [使用与配置指南](docs/USAGE.zh-CN.md)
- [故障排查](docs/TROUBLESHOOTING.md) · [帮助与反馈](SUPPORT.md)
- [源码安装与参与开发](CONTRIBUTING.md)
- [架构与数据流](docs/ARCHITECTURE.md) · [版本记录](CHANGELOG.md)

源码开发需要 macOS、Node.js 20.12+、Python 3.12 和 Xcode Command Line Tools，设置及检查步骤见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 开源与致谢

[MIT](LICENSE)。项目作者为 [yizhouxw](https://github.com/yizhouxw)。硬件触发工作流源自 [Johnixr/dji-mic-dictation](https://github.com/Johnixr/dji-mic-dictation)，保留上游 John Yin 的版权声明。另见[第三方声明](packaging/THIRD_PARTY_NOTICES.md)。

SpeekCoding 与 Apple、DJI、Karabiner-Elements、OpenAI 及模型提供方均无隶属或背书关系。
