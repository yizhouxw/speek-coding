# SpeekCoding

English · [简体中文](README.zh-CN.md)

SpeekCoding is a local-first dictation tool for macOS. Tap Fn to start live transcription and tap it again to finalize the text. The app copies the result to the clipboard, then optionally pastes it into the application that was active when recording started. It works with coding assistants, terminals, editors, and other text inputs.

## Requirements and project status

The menu's **License…** item opens an offline, scrollable document containing the project license, dependency and runtime notices, and model-weight licenses. Text can be selected and copied. Use **OK**, **Close**, Return, Escape, or the window close button to dismiss it.

- Apple Silicon: macOS 14 or later for Qwen3-ASR / MLX. Intel: macOS 13 or later with faster-whisper. A microphone is required.
- Karabiner-Elements for global Fn and optional DJI Mic Mini button triggers.
- Microphone permission for recording; Accessibility and event posting permissions for automatic paste and Return.

This is a `0.x` project. The repository starts from a new source snapshot; earlier development branches, tags, and release downloads have been removed. Public versions restart at `v0.1.0`. Get packages from [Releases](https://github.com/yizhouxw/speek-coding/releases), or follow the [source setup instructions](CONTRIBUTING.md#本地开发). Development packages marked `-dev-` are not Developer ID signed or notarized. A stable distribution must be signed and notarized separately.

## Install and use

When a package is available, choose the matching architecture from [Releases](https://github.com/yizhouxw/speek-coding/releases), install it, and open SpeekCoding from Applications. The package includes Node.js and the local Python ASR runtime; model weights are downloaded on first use.

Install and open [Karabiner-Elements](https://karabiner-elements.pqrs.org/), complete its system authorization, then run:

```bash
speek setup --trigger-mode keyboard
speek doctor
```

Select a microphone in the menu bar and grant the permissions shown there. Focus a text input, tap Fn, speak, and tap Fn again. Only a standalone Fn tap triggers recording; Fn combinations such as Fn+F12 retain their normal behavior. To add a connected DJI Mic Mini button:

```bash
speek setup --trigger-mode keyboard+dji --input-device "DJI Mic Mini"
```

By default, SpeekCoding pastes and presses Return. Uncheck **Auto-send (press Return after pasting)** under **Feature Settings** in the menu to paste without Return. Delivery can also be configured from the CLI:

```bash
speek config --delivery-mode paste_only
speek config --delivery-mode clipboard_only
speek config --delivery-mode paste_and_send
```

Settings apply to the next recording. A recording keeps the original target application's process ID; delivery fails if that process exits. It is not redirected to whichever application later has focus.

## Menu language

The menu and its dialogs support English, Simplified Chinese, and Traditional Chinese. By default, **Feature Settings → Language → Follow macOS** uses the first supported language in your macOS preferred language list. Chinese preferences for Taiwan, Hong Kong, and Macao select Traditional Chinese; unsupported languages fall back to English when no supported preference is available.

Choose **简体中文**, **繁體中文**, or **English** in that submenu to override the system language. The choice takes effect without restarting and is remembered after relaunch. Choose **Follow macOS** to restore the default. Menu language is independent of the ASR language; microphone device names come from macOS or the device.

## Common commands

```bash
speek status
speek trigger
speek cancel
speek config
speek restart
speek doctor
speek update
speek uninstall
```

`speek update` refreshes the installed integration from the CLI version being run; it is not an updater that downloads a new release. Cancel from the recording HUD, or press Fn again while transcription or model preparation is in progress. Test recordings made with `speek test-record` are kept at the requested output path.

## Transcription and privacy

Apple Silicon defaults to local **Qwen3-ASR-0.6B, 4-bit, accelerated by MLX**. Audio is sent to the local service while recording; the HUD shows a draft that can be corrected as you speak. Stopping flushes the remaining audio and finalizes before copying or pasting. Intel defaults to faster-whisper. Whisper, whisper.cpp, and OpenAI-compatible file transcription endpoints remain available.

Existing installations keep their configured engine. To switch an Apple Silicon installation after updating the app:

```bash
speek config --asr-backend qwen-mlx --asr-model mlx-community/Qwen3-ASR-0.6B-4bit
speek asr-install
speek restart
```

The model downloads on first use; cached weights are warmed when the service starts. Streaming uses 16 kHz mono audio and one-second decoding updates. If streaming disconnects, the app attempts file transcription using the retained temporary recording. `SPEEK_ASR_STREAMING=0` in the config disables live transcription. See the [configuration guide in Chinese](README.zh-CN.md#转写引擎).

Default transcription requests stay on the loopback interface. First-use model downloads and optional Karabiner downloads require network access. There is no built-in usage analytics or recording upload service. If you configure a remote ASR endpoint, audio is sent to that provider; HTTPS is required except for loopback addresses.

Ordinary temporary recordings and transcription state are cleaned up after a session. Explicit test recordings, downloaded model caches, and clipboard contents are retained. Logs and diagnostic reports can contain local paths, device names, and endpoints; redact them before sharing. See [SECURITY.md](SECURITY.md) for details and private vulnerability reporting.

## Development and support

Development requires macOS, Node.js 20.12+, Python 3.12, and Xcode Command Line Tools. Use Python 3.12 as `python3`; Python 3.13+ removed the `cgi` module used by the current local ASR server.

```bash
git clone https://github.com/yizhouxw/speek-coding.git
cd speek-coding
npm ci --ignore-scripts
npm run check
```

The checks cover the CLI, native app/HUD builds, isolated installation lifecycle, and the standalone NativeInput experiment. NativeInput is not integrated into the app and does not replace Karabiner. Passing its state tests does not establish hardware or permission compatibility.

- [Contribution workflow and source installation](CONTRIBUTING.md)
- [Help and issue reporting](SUPPORT.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Native input experiment](docs/NATIVE_INPUT_EXPERIMENT.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Release process](docs/RELEASING.md)
- [Changelog](CHANGELOG.md)
- [Code of conduct](CODE_OF_CONDUCT.md)

Maintainers work directly on `master`; external contributions start with an issue and are reviewed as patches or fork commits. The project does not use pull requests.

## License and acknowledgments

[MIT](LICENSE). SpeekCoding's project author is [yizhouxw](https://github.com/yizhouxw). The upstream John Yin copyright notice is retained in the license. Third-party runtime notices are in [packaging/THIRD_PARTY_NOTICES.md](packaging/THIRD_PARTY_NOTICES.md). Models and Karabiner-Elements are obtained separately and have their own licenses.

The hardware-trigger workflow originated from [Johnixr/dji-mic-dictation](https://github.com/Johnixr/dji-mic-dictation). SpeekCoding is not affiliated with or endorsed by Apple, DJI, Karabiner-Elements, OpenAI, or model providers.
