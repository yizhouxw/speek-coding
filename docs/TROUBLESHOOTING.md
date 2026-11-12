# SpeekCoding 故障排查

先运行：

```bash
speek status
```

输出中的 `next` 是当前最优先动作。需要查看 App 签名、IPC、权限、原生输入和 ASR 的完整细节时运行：

```bash
speek doctor
speek doctor --json
```

## 先确认已安装自包含 App

```bash
speek --version
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' \
  "/Applications/SpeekCoding.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "/Applications/SpeekCoding.app/Contents/Info.plist"
codesign --verify --deep --strict "/Applications/SpeekCoding.app"
```

确认版本与安装包一致，显示名为 `SpeekCoding`，Bundle ID 为 `com.speek.coding`，且 `codesign` 无错误。v0.3.1 起安装包在打开 App 时自动初始化和升级。仅在高级排障时可手动执行：

```bash
speek update --yes
```

更新会验证系统安装的 App、更新原生输入客户端并迁移旧托管规则，并清理已退役的旧运行时文件；它不会在用户机编译或重签 App。

## App 没有启动或 IPC 不可用

CLI 依赖 `SpeekCoding.app` 中的 agent。先手动启动，再检查状态：

```bash
open -gj "/Applications/SpeekCoding.app"
speek doctor
```

默认 IPC 文件应只属于当前用户：

```bash
uid="$(id -u)"
ls -ld "/tmp/speek-coding-$uid"
ls -l "/tmp/speek-coding-$uid/agent.sock"
ls -l "$HOME/.config/speek-coding/ipc-token"
```

状态目录应为 `drwx------`，socket 和 token 应只允许当前用户读写。不要复制、打印或提交 `ipc-token`。

常见错误：

- `AGENT_APP_MISSING`：重新安装与 Mac 架构匹配的 `.pkg`。
- `AGENT_START_FAILED`：确认 App 签名有效，并检查安全软件是否隔离或阻止了 `/Applications/SpeekCoding.app`。
- `AGENT_IDENTITY_MISMATCH`：socket 对端没有返回 `com.speek.coding` / 协议版本 1；停止异常进程后重新运行 `speek update`。
- `IPC_UNAUTHORIZED` 或 `AGENT_CREDENTIAL_UNREADABLE`：不要手工改 token；运行 `speek update --yes` 重新收口凭据和客户端。

如果安全软件曾拦截安装，先在它的事件记录中确认被阻止的路径和签名主体，仅为 `/Applications/SpeekCoding.app` 添加允许项，然后重新安装发布包。不要通过临时改名或 ad-hoc 重签绕过检查，否则 macOS 会把它视为新的权限主体。

## macOS 权限未就绪

SpeekCoding 的录音和自动粘贴权限属于 `SpeekCoding.app`。原生输入权限也属于 SpeekCoding：

- `Privacy & Security → Microphone`：允许 SpeekCoding。
- `Privacy & Security → Accessibility`：允许 SpeekCoding；这覆盖定向粘贴和 Return 所需的 AX / Event Posting 检查。
- `Privacy & Security → Input Monitoring`：允许 SpeekCoding，用于读取原生 Fn / DJI 触发。

不需要为 SpeekCoding 的录音和粘贴功能授权终端、Python、Shell 或 ASR LaunchAgent。其他映射工具占用输入设备时请退出它们。

先让产品 App 自己发起权限请求：

```bash
speek permissions
```

如果 Microphone 列表里还没有 SpeekCoding，也可以运行一次原生测试录音触发系统请求：

```bash
speek test-record --duration 2 --wav /tmp/speek-test.wav
```

如果 Accessibility 尚未出现，再运行 `speek permissions`，并按系统提示处理。完成后用产品自身的权限检查验证，不要用另一个进程代查：

```bash
speek doctor --json
```

如果系统设置中看似已允许，但菜单栏“自动粘贴和发送”仍提示需要授权，先重新打开菜单并用 `speek doctor --json` 分别检查 `accessibilityCurrentSession` 和 `postEventCurrentSession`。菜单会区分需要允许控制电脑和需要允许模拟按键；仅复制到剪贴板不需要这两项。再检查 App 签名是否有效：

```bash
codesign --verify --deep --strict "/Applications/SpeekCoding.app"
```

如果签名失效或升级后签名身份改变，重新安装可信的正式包并按系统提示重新授权。不要通过重签应用或关闭系统保护绕过问题。

## DJI 按钮没有触发

确认 Karabiner 能看到设备：

```bash
"/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli" --list-connected-devices
```

期望看到 `vendor_id = 11427`、`product_id = 16401` 和 `DJI MIC MINI`。再打开 Karabiner-EventViewer，按发射器连接键，正常事件为：

```json
{"consumer_key_code":"volume_increment"}
```

如果按键只调系统音量：

1. 在 Karabiner-Elements 的 `Devices` 页面打开 `DJI MIC MINI` 的 `Modify events`。
2. 如果同时出现 `Headset (Apple)`，也打开它。
3. 在 `Privacy & Security → Input Monitoring` 中允许 Karabiner-Elements。
4. 运行 `speek update --trigger-mode keyboard+dji`。

当前规则应只调用 `~/.config/karabiner/scripts/speek-command toggle dji`，不应包含录音、Python、GUI 自动化或明文 token。客户端错误会写入：

```bash
tail -n 80 "/tmp/speek-coding-$(id -u)/command.log"
```

如果 `speek trigger` 可用而硬件触发不可用，问题位于 Karabiner 设备、Input Monitoring、托管规则或 IPC 客户端，不在麦克风或 ASR。

如果 `speek trigger` 能显示 Island，但 Fn 完全无反馈，检查当前 profile 是否同时残留旧规则：

```bash
jq -r '.profiles[] | select(.selected == true) | .complex_modifications.rules[].description' \
  "$HOME/.config/karabiner/karabiner.json"
```

应只存在一条 SpeekCoding 托管规则，不应再有 `Fn dictation toggle + confirm/preconfirm to send Enter`。运行 `speek update --yes` 会删除使用绝对路径或 `~` 路径的旧规则并重新加载当前规则；随后 `speek doctor --json` 应报告 `profileCurrent: true`。

## HUD 有波形，但最后显示 No sound

这通常表示录音电平低，或当前输入不是目标麦克风。

```bash
speek test-record --duration 2 --wav /tmp/speek-test.wav
afinfo /tmp/speek-test.wav
```

依次检查：

1. 在 `System Settings → Sound → Input` 选择目标设备，确认系统电平会变化。
2. 用实际 CoreAudio 设备名更新配置：`speek config --input-device "DJI Mic Mini"`。
3. 在 `Privacy & Security → Microphone` 中确认 SpeekCoding 已允许。
4. 重新运行 `speek test-record`，确认输出 WAV 大小和时长正常。

录音由 App 内 AVAudioEngine 完成，不依赖 Python 音频库或 PortAudio 设备编号。

## ASR 显示 stopped 或 unavailable

```bash
speek restart
speek status
speek logs
```

直接检查默认健康接口：

```bash
curl http://127.0.0.1:8000/health
```

常见原因：

- `Bundled Python runtime is not executable` 或 `Python venv not found`：发布包不应创建 venv；重新安装与 Mac 架构匹配的 `.pkg`，再运行 `speek update --yes`。
- `Address already in use`：已有进程占用 8000 端口；停止冲突服务，或用 `speek config --asr-port 9000` 切换端口。
- `whisper.cpp binary/model not found`：检查 `--whisper-cpp-bin` 和 `--asr-model` 的绝对路径。
- 首次模型下载慢：用 `speek logs --follow` 查看进度，或先配置 `tiny` 模型验证。

前台运行服务以查看原始错误：

```bash
speek stop
speek asr-server
```

ASR 服务只处理 App 发来的 HTTP WAV 请求，不需要 Microphone、Accessibility 或 Event Posting 权限。若权限页正常而 ASR 不健康，应排查模型、端口和 Python 环境，不要给 LaunchAgent 增加 TCC 权限。

## 已转写但没有进入目标应用

先隔离 ASR 与事件交付问题：

```bash
speek config --delivery-mode clipboard_only
```

再次触发。如果剪贴板里有文字，说明录音和 ASR 正常，问题在 SpeekCoding 的 Accessibility / Event Posting 或目标应用状态。

1. 在 `Privacy & Security → Accessibility` 确认 SpeekCoding 已允许。
2. 确认录音开始时有正常前台应用；App 会锁定当时的 PID。
3. 确认该目标应用在转写完成前没有退出或重启。
4. 恢复：`speek config --delivery-mode paste_and_send`。

App 使用 `CGEvent.postToPid` 定向发送 Command-V 和可选 Return，不依赖转写完成瞬间的焦点，也不通过 GUI 脚本间接发送。

## Whisper 输出奇怪内容

- 录音过短、环境噪声大或输入设备错误都可能导致幻觉。
- 为混合中英文和代码标识符保留默认 prompt，或用 `--asr-prompt` 提供项目词汇。
- 先确认 WAV 有效，再提高模型质量。
- 中英混合输入不要固定为 `zh` 或 `en`；使用 `speek config --asr-language auto`。配置会保存为空语言提示，本地 whisper.cpp 实际使用 `-l auto`。

```bash
speek config \
  --asr-model whisper-large-v3-turbo \
  --asr-language auto \
  --fake-transcript ""
speek restart
```

只验证 App、IPC 和交付链路时，使用固定转写：

```bash
speek config --fake-transcript "请继续"
```

## 签名身份异常

发布包应始终使用同一个 Developer ID Application 身份。检查 App 的签名链和 designated requirement：

```bash
codesign -d --verbose=4 "/Applications/SpeekCoding.app"
codesign -d -r- "/Applications/SpeekCoding.app"
```

不要手工重签 App 来解决权限问题。签名主体发生变化会导致 Gatekeeper 校验或 TCC 权限归属异常，应重新安装由正确发布身份签名并公证的 `.pkg`。

## 配置、状态与日志位置

```text
/Applications/SpeekCoding.app
/usr/local/bin/speek
~/.config/speek-coding/config.env
~/.config/speek-coding/install-state.json
~/.config/speek-coding/ipc-token
~/.config/speek-coding/logs/asr.log
~/.config/speek-coding/logs/asr-error.log
~/.config/karabiner/scripts/speek-command
~/.config/karabiner/scripts/speek-hud
/tmp/speek-coding-<uid>/agent.sock
/tmp/speek-coding-<uid>/command.log
```

`config.env` 应通过 `speek config` 修改；不要把 token 写入命令、URL、日志或仓库。若手动修改 ASR 服务设置，运行 `speek restart` 让 LaunchAgent 重新生成。

## 重新安装

```bash
speek uninstall
# 重新安装与 Mac 架构匹配的 SpeekCoding-<版本>-<架构>.pkg
speek setup
```

SpeekCoding 只移除自己托管的当前用户 Karabiner 规则和文件，不删除其他规则，也不删除系统安装器管理的 App/CLI。模型缓存默认保留；新的 IPC token 会在设置时安全生成。
