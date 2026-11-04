# Contributing

感谢你愿意改进 SpeekCoding。参与前请阅读 [行为准则](CODE_OF_CONDUCT.md)；安全漏洞请按 [安全策略](SECURITY.md) 私密报告，不要创建公开 Issue。

## 贡献流程

本仓库的维护者采用 direct-to-`master` 流程，不使用 Pull Request。外部贡献者请先[创建 Issue](https://github.com/yizhouxw/speek-coding/issues)，说明动机、用户影响和方案；范围确认后，在自己的 fork 中准备提交，通过 Issue 提供不含私人信息的提交链接或补丁。维护者审查、验证后将变更应用到 `master`。不要在未讨论前投入大规模重构。

提交前可在自己的克隆中设置公开身份，避免公开公司邮箱或私人邮箱：

```bash
git config --local user.name YOUR_GITHUB_USERNAME
git config --local user.email YOUR_GITHUB_NOREPLY_EMAIL
```

将占位值替换为 GitHub 账户设置中显示的用户名和 noreply 邮箱。配置只影响新提交，不能清理已有提交元数据。

提交贡献即表示你有权提供相关代码、文档和资产，并同意按本项目的 [MIT License](LICENSE) 分发。请勿提交公司内部代码、客户数据、模型权重、录音、证书、私钥、token 或来源/许可证不明确的二进制资产。

## 本地开发

要求：macOS、Node.js 20.12+、Python 3.12、Xcode Command Line Tools，以及可用的登录钥匙串。当前本地 ASR 代码使用 Python 3.12 的 `cgi` 模块，Python 3.13 及更新版本已移除该模块。安装依赖并运行完整验证：

```bash
git clone https://github.com/yizhouxw/speek-coding.git
cd speek-coding
npm ci --ignore-scripts
npm test
```

确认 `python3 --version` 是 Python 3.12；如果系统默认版本不同，请先将 Python 3.12 的可执行文件目录放到 `PATH` 前部。仅设置 `PYTHON3_BIN` 不会改变测试调用的 `python3`。

`npm test` 会运行 Node.js 单元测试、JavaScript/Shell/Python 语法检查、Karabiner JSON 校验、独立 `NativeInput` Swift Package 的状态机测试，并把 `scripts/speek-coding-app.swift` 和 HUD 编译为临时 Mach-O 产物。原生 App 变更必须在支持对应 macOS frameworks 的机器上验证。

要在开发 Mac 上安装源码版，请先安装并打开 Karabiner-Elements，再运行：

```bash
node cli/index.mjs setup --trigger-mode keyboard --delivery-mode paste_only
node cli/index.mjs doctor
```

此操作会安装或更新 `~/Applications/SpeekCoding.app`、当前用户的服务与 Karabiner 托管规则，创建或复用本机开发签名，并为本地 ASR 安装 Python 依赖。已有安装的签名身份不一致时会明确停止，请使用独立测试账户验证，不要强行覆盖签名。源码运行 CLI 使用 `node cli/index.mjs <command>`；安装包提供的入口才是 `speek <command>`。普通自动测试和生命周期烟测不需要修改真实安装。

`NativeInput/` 是尚未接入 App 的实验库；运行 `swift test --package-path NativeInput` 只测试状态机，不启动监听器或请求系统权限。实验的目标、接口与硬件验证限制见[原生输入实验](docs/NATIVE_INPUT_EXPERIMENT.md)。

提交前再执行：

```bash
npm run smoke
npm pack --dry-run
npm run security:audit
git diff --check
```

## 生命周期烟测

`npm run smoke` 使用临时安装目录和模拟依赖执行 `setup → status → uninstall`，验证源码 App 的构建签名、IPC 文件、Karabiner 托管规则和清理流程，不会改动开发者真实的 Karabiner 配置。烟测使用 ad-hoc 测试签名、跳过 App 启动和真实权限检查，因此不能替代真实设备验证。

烟测依赖 macOS 的 `swiftc` 和 `codesign`。若测试环境使用显式测试签名或跳过 App 启动，必须通过脚本已有的环境变量注入，不能修改生产默认值来适配 CI。

## 构建最终用户安装包

开发构建会为当前 Mac 架构生成自包含包，并在展开后的 payload 中运行内置 Node.js、Python/faster-whisper 和 CLI 验证。若钥匙串中已存在 `SpeekCoding Local Code Signing` 身份，默认复用它并不请求时间戳；否则使用 ad-hoc 签名。也可用 `SPEEK_APP_SIGNING_IDENTITY` 指定身份，非发布构建可用 `SPEEK_APP_SIGNING_TIMESTAMP=0` 禁用时间戳：

```bash
npm run package:mac
# dist/SpeekCoding-<version>-<arm64|x86_64>.pkg
```

脚本固定并校验 Node.js 与 python-build-standalone 下载的 SHA-256，在 App 内安装 production Node 依赖和 faster-whisper。`arm64` 与 `x86_64` 包必须分别在对应架构的构建机上生成；脚本拒绝未验证的交叉构建。

正式分发必须提供 Apple 签名身份；如已配置 notarytool keychain profile，还会自动提交公证并 staple：

```bash
SPEEK_RELEASE=1 \
SPEEK_APP_SIGNING_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
SPEEK_INSTALLER_SIGNING_IDENTITY="Developer ID Installer: Example Corp (TEAMID)" \
SPEEK_NOTARY_PROFILE="speek-notary" \
npm run package:mac
```

Node.js、Python、npm、Swift/Xcode CLI 和签名证书都是构建机依赖；安装 `.pkg` 的最终用户不需要这些工具。

Python 打包依赖的版本源文件是 `packaging/requirements-asr.in`，发布构建实际读取带 SHA-256 的 `packaging/requirements-asr.txt`。更新版本后必须使用 `uv` 重新生成锁文件并在两种 Mac 架构上验证：

```bash
uv pip compile packaging/requirements-asr.in \
  --universal --python-version 3.12 --generate-hashes \
  --no-annotate --no-header --only-binary :all: \
  -o packaging/requirements-asr.txt
```

## 不可破坏的产品边界

所有运行时改动都必须维持以下约束：

- 产品 App 名固定为 `SpeekCoding`，Bundle ID 固定为 `com.speek.coding`。
- 麦克风采集、权限检测、剪贴板和 CGEvent 交付只在 `SpeekCoding.app` 进程内实现。
- CLI 通过带 token 的每用户 Unix socket 调用 App，不实现第二套录音状态机。
- Karabiner 规则只调用最小 IPC 客户端，不嵌入录音、转写、GUI 自动化或凭据。
- 单独按 Fn 才触发录音；Fn 组合键必须保留系统与其他应用的行为。原生输入实验不能在没有迁移验证时替换现有触发路径。
- URL Scheme 只允许鉴权后的 `toggle` / `cancel`，不能接受配置覆盖。
- ASR LaunchAgent 只提供转写 endpoint，不获取 Microphone、Accessibility 或 Event Posting 权限。
- 录音开始时锁定目标应用 PID，事件交付使用定向 `postToPid`，不能静默改投另一个窗口。

如果新能力需要扩大这些边界，应先更新威胁模型、架构文档和迁移方案，而不是增加临时辅助进程。

## 安装与签名变更

安装流程必须保持以下顺序和性质：

1. 生成或复用权限为 `0600` 的随机 IPC token。
2. 源码安装编译标准 App bundle；发布包安装验证构建机预编译、预签名的 App bundle。
3. 发布包执行严格签名验证；发布流程须核查固定 Developer ID 和身份连续性。源码安装会检查并拒绝已有签名身份或 designated requirement 的意外变化。
4. App 鉴权 `ping` 成功后再启用新的 Karabiner 托管规则。
5. 最后清理上一版本的运行时入口。

不要为方便测试把生产安装改为 ad-hoc 签名，也不要在升级时无条件重建证书。涉及 Info.plist、entitlement、designated requirement 或钥匙串操作的变更，必须在真实升级场景中验证权限身份是否保持稳定。

## 变更要求

- 用户可见行为需要同步 README 和 CHANGELOG。
- 配置变更必须兼容读取上一版本；旧路径只可用于迁移清理，不能重新进入运行时。
- 安装、升级和卸载必须幂等，且不能覆盖非 SpeekCoding 托管的 Karabiner 内容。
- IPC 变更需要覆盖鉴权失败、同 UID、socket 权限、对端身份和请求大小测试。
- 原生状态机变更需要覆盖忙碌、取消、权限拒绝、无声录音、ASR 失败和目标应用退出。
- 后台服务变更需要覆盖 plist 生成和健康探测测试，并保持无敏感 TCC 权限；内置 Python 运行和模型下载子进程不得在签名 App 内写入字节码。
- 安全相关错误必须明确失败，不得静默回退到未签名 App、无鉴权 socket 或公开 URL。

提交前请按[开源维护检查](docs/OPEN_SOURCE.md)扫描待提交文件。脱敏诊断信息后再提交 Issue；安全问题使用 [SECURITY.md](SECURITY.md) 中的私密渠道。
