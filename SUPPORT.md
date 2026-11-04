# 获取帮助与反馈

安装与日常使用见 [README](README.md)（[English](README.en.md)），已知排查步骤见[故障排查](docs/TROUBLESHOOTING.md)。请先运行 `speek status` 和 `speek doctor` 检查本机服务、权限及当前 Karabiner 规则。

普通缺陷和功能建议请使用 [GitHub Issues](https://github.com/yizhouxw/speek-coding/issues)。维护者不承诺固定响应时间；请避免重复提交相同问题。

## 缺陷报告

请提供：

- SpeekCoding 版本、安装来源（源码或开发包）、macOS 版本、Apple Silicon/Intel。
- 键盘或 DJI 触发方式、Karabiner-Elements 版本、是否使用远端转写服务。
- 最小复现步骤、期望行为和实际行为，以及能否稳定复现。
- 已做的排查；仅在必要时附上经过脱敏的诊断片段。

分享截图、日志或 `speek doctor --json` 前，删除用户名、绝对路径、设备序列号、私人 endpoint、API key、IPC token、录音和转写正文。不要把完整配置目录、钥匙串导出文件或原始录音作为附件。

## 功能建议与贡献

请描述实际场景、现有行为为何不足及预期效果。涉及 Fn 组合键、权限、录音生命周期或文字交付的改动，请说明兼容性和回退需求。代码贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 安全问题

漏洞及疑似凭据泄露请走 [SECURITY.md](SECURITY.md) 的私密报告渠道，不要使用普通 Issue 表单。
