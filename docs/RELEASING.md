# 发布流程

本文件是维护者发布公开版本时的最低检查清单。正式发布只能从干净、已同步的 `master` 构建；不要从个人分支、含未提交改动的工作树或来源不明的缓存产物发布。

## 发布前

1. 确认有权公开代码、文档、商标和二进制资产，并完成适用的雇主/组织开源审批。
2. 检查 Git 历史中的作者邮箱、Issue、日志和历史文件名是否适合公开；不要在没有明确备份和协作方案时改写已发布历史。
3. 更新 `package.json` 版本和 `CHANGELOG.md`，确认版本符合 Semantic Versioning。
4. 审查 `LICENSE`、`SECURITY.md`、`packaging/THIRD_PARTY_NOTICES.md` 与依赖许可证。
5. 运行密钥扫描；任何真实凭据都必须先撤销/轮换，再决定是否清理历史。

## 依赖与验证

```bash
npm ci
npm run check
uvx pip-audit --no-deps --disable-pip \
  --requirement packaging/requirements-asr.txt
git diff --check
```

如果更新 Python 依赖，先编辑 `packaging/requirements-asr.in`，再按 `CONTRIBUTING.md` 的命令重新生成带哈希的锁文件。Node.js、python-build-standalone 下载地址与 SHA-256 必须成对更新，禁止只改版本号或跳过校验。

## 构建与签名

### GitHub Actions 开发预发布

`.github/workflows/release.yml` 在推送 `vX.Y.Z` 标签时运行，也可在 Actions 中选择已有标签手动重试。标签必须带注释，指向 GitHub `master` 的最新提交，并与 `package.json` 版本及 `CHANGELOG.md` 中非空的 `## [X.Y.Z]` 节一致。

流水线分别在 arm64 和 Intel macOS 上运行测试、构建及包验证，全部成功后创建 GitHub **开发预发布**，上传文件名带 `-dev-` 的两个安装包和 `SHA256SUMS.txt`。安装器未签名、未公证；标准干净 runner 没有本机开发身份时，App 使用 ad-hoc 签名。仅供开发验证，不应作为正式发布。macOS 可能阻止安装或运行，升级后权限也可能需要重新授权。不需要配置 Apple 签名凭据。

确认目标 GitHub 仓库及发布权限，更新版本和变更记录，提交并推送后执行：

```bash
git tag -a vX.Y.Z -m 'SpeekCoding vX.Y.Z'
git push <github-remote> vX.Y.Z
```

将示例版本和远程名替换为实际值。不要重用已发布的标签或覆盖已有 Release；日常开发仍直接推送到所有已配置远端的 `master`。此开发包不得提升为正式发布，正式分发必须另行使用 Developer ID 签名及公证。

### 本地构建

arm64 与 x86_64 必须分别在对应架构的受控 Mac 上构建：

```bash
SPEEK_RELEASE=1 \
SPEEK_APP_SIGNING_IDENTITY="Developer ID Application: Example Corp (TEAMID)" \
SPEEK_INSTALLER_SIGNING_IDENTITY="Developer ID Installer: Example Corp (TEAMID)" \
SPEEK_NOTARY_PROFILE="speek-notary" \
npm run package:mac
```

构建脚本必须成功完成签名、公证、staple、展开验证和 package smoke test。发布前再在一台未参与构建的受支持 Mac 上执行：

```bash
pkgutil --check-signature SpeekCoding-<version>-<arch>.pkg
spctl --assess --type install --verbose=2 SpeekCoding-<version>-<arch>.pkg
shasum -a 256 SpeekCoding-<version>-<arch>.pkg
```

上述 `<...>` 是占位说明，执行时替换为实际文件名。Developer ID、notary profile、私钥和 API token 只能存在于受控密钥存储或 CI secret 中，不能写入命令历史、仓库、构建日志或发布附件。

## 发布内容

- 创建与 `package.json` 一致的带注释版本标签。
- 发布源代码、arm64/x86_64 `.pkg`、每个文件的 SHA-256、签名主体和最低 macOS 版本。
- 发布说明列出用户可见变化、修复的安全问题、升级/回滚注意事项和已知限制。
- 确认安装包中的第三方许可证文件完整；模型权重不随包分发，并提醒用户遵守模型许可证。
- 安装、升级、`speek doctor`、`speek test-record` 和卸载各验证一次，再将版本标记为稳定。

Ad-hoc 签名包只能作为标明用途的开发预发布产物，不能作为正式 Release。
