# Security

## 支持范围

安全修复只保证进入最新发布版本和 `master`。旧版本可能不再单独回补；报告问题时请注明 SpeekCoding、macOS 和 Mac 架构版本。

## 私密报告

GitHub 仓库启用私密漏洞报告后，请使用 [Report a vulnerability](https://github.com/yizhouxw/speek-coding/security/advisories/new)。若入口不可用，请通过[维护者公开个人资料](https://github.com/yizhouxw)中提供的私密联系方式联系，并注明 `SpeekCoding security`；如果没有可用联系方式，可创建仅请求私密联系渠道的 Issue，不附任何漏洞细节。提交中的 noreply 邮箱不能接收安全报告。不要在公开 Issue 中提交录音、转写内容、API key、IPC token、签名私钥、个人路径、未脱敏日志或可直接利用的漏洞细节。

报告请尽量包含受影响版本、macOS 版本、影响、最小复现步骤和建议的披露时间。维护者会先确认收到，再协商修复与公开时间；在修复版本发布前请勿公开利用细节。

## 信任边界

SpeekCoding 把 macOS 敏感能力收口到稳定签名的 App。正式安装包路径是 `/Applications/SpeekCoding.app`；源码开发安装默认使用 `~/Applications/SpeekCoding.app`：

- App 显示名：`SpeekCoding`
- Bundle ID：`com.speek.coding`
- 麦克风：App 内 AVFoundation / AVAudioEngine
- Accessibility 与 Event Posting：App 内 AX / CoreGraphics
- 剪贴板与粘贴：App 内 AppKit / `CGEvent.postToPid`

CLI、Karabiner IPC 客户端、Shell、Python 和 ASR LaunchAgent 不负责 SpeekCoding 的录音或文字交付。Karabiner-Elements 独立读取和处理全局输入；它的 Input Monitoring、辅助功能、后台服务和驱动等授权以其安装引导为准。

`NativeInput/` 是独立实验包，尚未链接进 App 或安装包。它只包含非独占 HID 观察和 listen-only event tap；没有实现录音、事件屏蔽或替代 Karabiner 的产品流程。单独运行状态机测试不请求输入监控权限，宿主实际启动观察者则需要相应授权。

## 本机签名

正式发布包必须使用固定的 Apple Developer ID Application / Installer 身份，完成 hardened runtime 签名、公证和 staple。源码安装会创建或复用登录钥匙串中的 `SpeekCoding Local Code Signing` 身份，并在替换本地 App 前验证签名；源码安装检测到已有身份或 designated requirement 变化时会停止。包内安装路径会验证当前 App 签名并把 designated requirement 记入 manifest，但不会将其与旧 manifest 比较，因此发布流程必须自行确保升级使用正确身份。

非发布的本机打包默认复用已有的 `SpeekCoding Local Code Signing` 身份；不存在时回退为 ad-hoc 签名，也可显式指定身份。本机稳定签名只用于开发，不等同于 Apple Developer ID 分发签名或公证。私钥存放在用户登录钥匙串中，卸载默认保留该身份，以便重新安装时延续同一开发身份。不要导出、提交或在不受信任的机器上复制私钥。

## IPC

默认 socket 位于 `/tmp/speek-coding-<uid>/agent.sock`，状态目录权限为 `0700`，socket 权限为 `0600`。App 会拒绝符号链接或不属于当前用户的状态目录，并通过 `getpeereid` 拒绝不同 UID 的连接。

每个请求还必须携带 `~/.config/speek-coding/ipc-token` 中的 256-bit 随机 token；该文件权限为 `0600`。IPC 使用单行 JSON，单条请求最大 1 MiB。CLI 会验证对端返回 `com.speek.coding` 和受支持的协议版本。

Karabiner 只调用最小化的 `speek-command` IPC 客户端。不要把 token 写入 Karabiner 配置、命令行参数、日志、Issue 或仓库。

## URL Scheme

`speekcoding://` 是受保护的可选入口，不是公开控制 API。App 只接受 `toggle` 和 `cancel`，要求有效 token，并且只采纳长度受限的 `source` 标签；URL 不能覆盖麦克风、ASR endpoint、交付模式、文件路径或其他配置。

由于 URL 可能出现在浏览器历史、进程参数或日志中，内置 Karabiner 规则默认不用 URL 传 token，而使用 Unix socket。第三方集成若无法保护凭据，应使用 CLI，不应拼接 URL。

## 目标应用交付

App 在录音开始时记录前台应用 PID。转写完成后，Command-V 和可选 Return 通过 `CGEvent.postToPid` 定向发送给同一进程；如果目标已经退出，交付失败，不会自动改投当前前台窗口。`clipboard_only` 模式只写剪贴板，不发送 CGEvent。

## 音频与 ASR 数据

内置 ASR endpoint 只允许绑定 localhost 或 loopback IP，单次请求默认上限为 256 MiB，并拒绝客户端临时切换模型。App 在当前用户专属的 `/tmp/speek-coding-<uid>/` 中创建临时 WAV 和 HUD 状态；常规会话无论成功、失败或取消都会清除录音与完整转写状态，App 下次启动也会清理异常退出遗留的常规录音。只有用户明确运行 `speek test-record` 时才保留指定的测试 WAV。本地 ASR LaunchAgent 只接收 HTTP 音频请求并返回文本，不需要麦克风、Accessibility 或 Event Posting 权限。内置 Python 的服务、前台运行及模型下载子进程禁用字节码写入，避免修改签名 App 内的资源。

配置外部 `--asr-url` 会由 `SpeekCoding.app` 把音频发送到对应服务。远端 endpoint 必须使用 HTTPS；明文 HTTP 只允许 loopback 地址。使用者仍需自行确认该服务的鉴权、留存和隐私策略；SpeekCoding 不会把远端 endpoint 自动降级或替换为本地端点。

后台日志不应记录音频正文、IPC token、API key 或完整转写内容。如发现泄露，请按安全事件处理并轮换相关凭据。

## API 凭证

SpeekCoding 配置只保存 API key 的环境变量名称，不把 key 值写入 `config.env`。不要把密钥直接写入配置、LaunchAgent plist、命令参数或仓库文件。

## 安全软件与企业策略

安全软件可能阻止本机 Swift 编译、钥匙串证书导入、代码签名或首次启动。应根据拦截记录为明确的 App 路径和签名主体添加最小允许范围，然后重新运行 `speek update --yes`。不要通过关闭整机防护、临时改名或 ad-hoc 重签规避；这些操作会削弱边界并可能使 TCC 权限失效。

公开讨论普通安全加固建议时仍需先删除 `speek doctor --json` 中的用户名、绝对路径、设备信息和 endpoint；不确定时按漏洞报告处理并使用私密渠道。
