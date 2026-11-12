# 开发说明

源码构建、测试和贡献流程见 [CONTRIBUTING.md](../CONTRIBUTING.md)；架构和发布流程分别见 [ARCHITECTURE.md](ARCHITECTURE.md) 和 [RELEASING.md](RELEASING.md)。

`NativeInput/` 静态链接进 App。Fn 和 DJI 原生监听默认开启；安装、升级和运行无需 Karabiner。客户端与 HUD 存放在 `~/.config/speek-coding/bin`。历史诊断记录见 [NATIVE_INPUT_EXPERIMENT.md](NATIVE_INPUT_EXPERIMENT.md)。

## 产品身份与签名

发布构建在构建机上把 Swift 源码编译为原生 Mach-O App，并在装入 `.pkg` 前完成签名。最终用户的 Mac 不会运行编译器或创建本机开发证书。正式对外分发应使用固定的 Apple Developer ID Application / Installer 身份并完成公证，这使版本升级继续归属于同一个 macOS 权限主体。

开发构建默认复用已有的 `SpeekCoding Local Code Signing` 身份，不存在时使用 ad-hoc 签名；这些包仅用于开发验证，不应作为正式分发物。可用以下命令核验实际产物：

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' \
  "/Applications/SpeekCoding.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "/Applications/SpeekCoding.app/Contents/Info.plist"
codesign --verify --deep --strict "/Applications/SpeekCoding.app"
codesign -d -r- "/Applications/SpeekCoding.app"
```

前两条命令应分别输出 `SpeekCoding` 和 `com.speek.coding`。

## 悬浮窗与集成接口

HUD 会使用 AppKit 的屏幕安全区识别 MacBook 顶部摄像头缺口：有硬件缺口时，黑色状态面板贴合物理屏幕顶边并围绕缺口显示；没有缺口的内建屏幕或外接显示器继续使用顶部居中的悬浮胶囊。

CLI 的录音触发、取消、权限检查和测试录音通过每用户 Unix socket `/tmp/speek-coding-<uid>/agent.sock` 调用 App。请求需要 `~/.config/speek-coding/ipc-token` 中的随机凭据；socket、状态目录和 token 都限制为当前用户访问。

Karabiner 规则只执行已安装的 `speek-command` 客户端，由它携带同一凭据发送 `toggle`。App 也注册了 `speekcoding://` URL Scheme 作为受保护的可选入口，但只接受带有效 token 的 `toggle` / `cancel`，且不接受配置覆盖。


## Offline correction quality checks

The normal tests mock model execution and never download weights. After downloading a text model from Model Management, run `python3 test/evaluate-correction.py <model-id>` with the MLX runtime Python to evaluate the small, multi-topic fixture set. The script checks preservation of key content and removal of hesitation sounds and prints latency; it is a regression sample, not a comprehensive quality benchmark.
