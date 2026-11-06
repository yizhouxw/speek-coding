# SpeekCoding 架构

## 运行时数据流

```text
CLI: speek trigger / cancel / test-record / permissions
                         │
                         │ authenticated JSON over Unix socket
                         ▼
Fn / DJI HID ─► Karabiner ─► speek-command ───────────────┐
                                                          │
                                                          ▼
                                               SpeekCoding.app
                                               com.speek.coding
                                                   │
                         ┌─────────────────────────┼──────────────────────────┐
                         │                         │                          │
                         ▼                         ▼                          ▼
                 AVAudioEngine / CoreAudio   permission APIs          AppKit / CGEvent
                         │                  AVFoundation / AX / CG      pasteboard + postToPid
                         ▼                         │                          │
                 mono PCM16 stream / WAV                   │                          ▼
                         │                         │                 recording-start target PID
                         ▼                         │
                 URLSession PCM sessions / multipart              │
                         │                         │
                         ▼                         │
               OpenAI-compatible ASR ◄─────────────┘
                         │
                         ▼
                    transcript
```

使用本地 ASR 时，OpenAI-compatible endpoint 由另一个非敏感进程提供：

```text
com.speek.coding.asr LaunchAgent
        │
        ├── Qwen3-ASR-0.6B 4-bit / MLX (Apple Silicon, default)
        ├── faster-whisper
        └── whisper.cpp
```

ASR LaunchAgent 不打开音频设备、不读剪贴板、不发送键盘事件，也不检测 TCC 权限。它只在 loopback 接收 App 发出的 HTTP PCM 流或 WAV 请求并返回文本；服务限制请求大小并拒绝请求级模型覆盖，避免被误暴露到局域网或用于触发任意模型下载。

App 启动时在配置为本地 ASR 且未使用模拟转写时尝试启动已安装的服务，正常退出时卸载当前会话中的服务；LaunchAgent 的登录启动和 `speek start` / `speek stop` 仍可独立管理服务。内置 Python 在服务、前台服务和模型下载进程中禁用字节码写入，以保护 App 签名。

语言配置中的 `auto` 会规范化为空值：App 不向外部 OpenAI-compatible endpoint 发送固定语言代码，faster-whisper 使用自身自动检测，本地 whisper.cpp 则显式补充 `-l auto`，避免其省略参数时默认偏向英文。默认 prompt 对中英文保持对称，并要求保留原始 code-switching、代码标识符、命令和文件名。

## 单一权限主体

`SpeekCoding.app` 是唯一需要 macOS 敏感权限的产品进程：

| 能力 | 进程内实现 | macOS 权限主体 |
| --- | --- | --- |
| 麦克风采集 | `AVAudioEngine`、CoreAudio | SpeekCoding |
| 麦克风授权状态与请求 | `AVCaptureDevice` | SpeekCoding |
| Accessibility 检测与提示 | AX API | SpeekCoding |
| 剪贴板写入 | `NSPasteboard` | SpeekCoding |
| 定向粘贴与 Return | `CGEvent.postToPid` | SpeekCoding |

Karabiner-Elements 独立于产品 App：它读取全局键盘/HID 事件，并可能要求 Input Monitoring、辅助功能、后台服务及驱动扩展等权限，具体以其设置引导为准。CLI、Shell、Python 和 ASR LaunchAgent 不承担 SpeekCoding 的录音或文字交付权限。

App 的产品身份固定为：

- `CFBundleDisplayName = SpeekCoding`
- `CFBundleName = SpeekCoding`
- `CFBundleExecutable = SpeekCoding`
- `CFBundleIdentifier = com.speek.coding`

## 调用入口

### CLI

`cli/lib/agent.mjs` 负责启动 App、验证 IPC 对端返回的 Bundle ID 与协议版本，并把 `speek trigger`、`speek cancel`、权限检测和 `test-record` 等运行时命令发送到 Unix socket。

默认 IPC 位置：

- socket：`/tmp/speek-coding-<uid>/agent.sock`
- 凭据：`~/.config/speek-coding/ipc-token`

状态目录权限为 `0700`，socket 和 token 权限为 `0600`。App 还校验连接端与自身属于同一 UID，并要求每个 JSON 请求携带安装时生成的 256-bit 随机 token。请求按行编码，单条上限为 1 MiB。

### Karabiner

托管规则不包含录音、转写或事件注入逻辑。它只执行：

```text
~/.config/karabiner/scripts/speek-command toggle fn
~/.config/karabiner/scripts/speek-command toggle dji
```

`speek-command` 只负责在需要时启动 App、读取 `0600` token，并通过同一个 Unix socket 发送 `toggle`。这使 CLI 与硬件触发共享同一状态机和权限主体。

### URL Scheme

App 注册 `speekcoding://` 作为可选集成入口。URL 只接受 `toggle` 和 `cancel`，必须携带正确 token；除受限的 `source` 标签外，URL 参数不能覆盖音频、ASR 或交付配置。当前 Karabiner 规则默认使用鉴权 IPC 客户端，不把 token 暴露在规则或 URL 中。

## App 内状态机

```text
idle ── toggle/save ──► starting ──► recording ── toggle/watch ──► transcribing ──► idle
  │                           │
  └──── test-record ─────────► testing ────────────────────────────────────────► idle
```

- 开始录音时，App 记录当前前台应用的 PID；如果发送模式不是 `clipboard_only` 且没有可用目标，录音不会启动。
- 录音由 App 内 `AVAudioEngine` 完成，并生成单声道 16-bit WAV。
- App 用 `URLSession` 把 WAV 发送到配置的 ASR endpoint；远端 endpoint 必须使用 HTTPS，HTTP 只允许 loopback。
- 转写完成后，App 先写入 `NSPasteboard`，再将 Command-V 和可选 Return 定向 `postToPid` 给录音开始时的目标应用。
- 常规会话结束、失败或取消时删除临时 WAV 和完整转写状态；只有显式 `test-record` 输出会保留。
- HUD 是只读状态展示；它通过 `NSScreen.safeAreaInsets` 与顶部辅助区域识别摄像头缺口，在支持的 MacBook 上贴合物理顶边并围绕缺口布局，在其他屏幕上保留顶部悬浮胶囊。HUD 失败不会改变录音状态机。

## 构建、签名与升级

发布构建在构建机上使用 `swiftc` 编译 `scripts/speek-coding-app.swift` 和 HUD，并把预编译产物、固定 Node.js、可重定位 Python 以及 faster-whisper 一起装入 App bundle。`.pkg` 只把这些产物复制到用户机；用户机不执行 Swift 编译、`npm install`、Python venv 创建或 `pip install`。

正式发布要求固定的 Developer ID Application 身份签 App、Developer ID Installer 身份签 `.pkg`，并完成公证和 stapling。`speek update` 验证已安装的包内 App 签名，在 manifest 中记录 designated requirement，再协调每用户文件；它不重签或替换包内 App，也不比较发布包与旧 manifest 的签名身份。源码安装路径会检查现有身份是否变化。开发构建在已有 `SpeekCoding Local Code Signing` 身份时默认复用，否则使用 ad-hoc 签名，均不作为正式分发物。

安装/升级顺序保证 Karabiner 不会在 App 就绪前切换到新入口：

1. `.pkg` 把已签名 App、内置运行时和 CLI launcher 安装到系统位置。
2. `speek setup` 检查 Karabiner，生成或复用 IPC token，准备 IPC 客户端和 HUD。
3. 验证已安装 App 的签名、注册 LaunchServices，并通过鉴权 `ping` 检查 Bundle ID 和协议版本。
4. 写入指向 App 内 Python 的配置和 Karabiner 托管规则，清理旧入口；未跳过 ASR 时，准备并启动本地服务。

## 组件职责

- `scripts/speek-coding-app.swift`：原生 App、权限、录音、ASR HTTP、状态机和定向交付。
- `cli/lib/agent.mjs`：Node.js 鉴权 IPC 客户端与 App 启动/身份检查。
- `scripts/speek-command.sh`：Karabiner 使用的最小鉴权 IPC 客户端。
- `cli/index.mjs`：用户命令编排和交互。
- `cli/lib/actions.mjs`：源码安装签名、安装、升级、诊断和卸载。
- `cli/lib/service.mjs`：ASR LaunchAgent 生成、生命周期和健康探测。
- `cli/lib/config.mjs`：配置规范化、旧配置迁移和序列化。
- `scripts/local-asr-server.py`：faster-whisper / whisper.cpp 的本地兼容接口。
- `scripts/speek-hud.swift`：不抢焦点的只读状态 HUD。

## 持久化位置

| 路径 | 内容 |
| --- | --- |
| `/Applications/SpeekCoding.app` | 原生产品 App、CLI、Node.js、Python/faster-whisper 与静态资源 |
| `/usr/local/bin/speek` | 调用 App 内 Node.js/CLI 的固定 launcher |
| `~/.config/speek-coding/config.env` | 产品配置 |
| `~/.config/speek-coding/install-state.json` | 安装版本、路径、Bundle ID 与签名信息 |
| `~/.config/speek-coding/ipc-token` | `0600` IPC 随机凭据 |
| `/Applications/SpeekCoding.app/Contents/Resources/runtime/python/` | 安装包内的可重定位 ASR Python 环境 |
| `~/.config/speek-coding/logs/` | ASR 服务日志 |
| `~/.config/karabiner/scripts/speek-command` | Karabiner IPC 客户端 |
| `~/.config/karabiner/scripts/speek-hud` | 原生 HUD 可执行文件 |
| `~/Library/LaunchAgents/com.speek.coding.asr.plist` | 本地 ASR LaunchAgent |
| `~/.config/speek-coding/com.speek.coding.asr.plist` | 无法写登录项时的当前会话 fallback |
| `/tmp/speek-coding-<uid>/` | socket、会话期临时 WAV 和 HUD 状态；仅当前用户可访问 |
| `~/.cache/speek-coding/` | 可选模型与 whisper.cpp 构建缓存 |

## 兼容性约定

新配置统一使用 `SPEEK_*` 环境变量。安装器仍能识别旧安装路径和旧 Karabiner 托管规则，仅用于迁移清理；已退役的旧录音状态机不再安装或运行。

迁移识别同时覆盖 `~/.config/...` 和安装后物化的 `/Users/<name>/.config/...` 绝对命令路径，并识别 0.1.x 的旧规则描述。`doctor` 只有在目标 profile 中恰好存在一条且内容与当前模板一致的托管规则时才报告 `profileCurrent=true`，避免旧规则在前抢先吞掉 Fn。

## 实时转写

Qwen 使用同一 loopback HTTP 服务提供 `/v1/audio/streams` 会话接口。App 以约 200 ms 聚合录音回调，按顺序发送 PCM16；服务每秒解码，返回完整草稿以替换上一版。所有模型加载和推理都归同一线程所有，避免 Metal 跨线程上下文问题。窗口限制为 20 秒，长录音在接近停顿的窗口边界提交；单次录音上限为 5 分钟。30 秒上下文在本机的 44 秒重复口述回放中出现了整句重复，因此使用更短的窗口，保留音频里真实的重复，不对输出文字做去重。

POST `/v1/audio/streams` 接收 JSON（model、language、prompt、sample_rate=16000），返回随机会话 id。POST `/{id}/append` 接收 little-endian PCM16 单声道音频，Content-Type 为 application/octet-stream，X-Speek-Sequence 从 0 递增；每块最多 64000 字节。所有音频发完后向 `/{id}/finish` POST 一个哨兵字节，使用下一个序号，返回 is_final=true。`/{id}/cancel` POST 一个字节释放会话。拒绝浏览器 Origin、乱序、超限、过期、并发录音和请求级模型替换。

HUD 从独立的 live_transcript 状态显示最近草稿，草稿不会写入剪贴板。停止时先停止采集，排空剩余分块，再定稿。流式失败时保留 WAV 作同模型文件转写回退；取消或旧会话回调不得触发交付。传统文件接口与非 Qwen 引擎继续可用。

可用原生 App 可执行文件的 `--streaming-self-test <transcription-url> <model> <16000-Hz-mono-WAV>` 重放音频验证真实客户端，无需打开麦克风或写入剪贴板；添加 `--cancel` 验证取消。
