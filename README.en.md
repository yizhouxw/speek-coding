# SpeekCoding

English · [简体中文](README.md)

SpeekCoding is a local-first dictation tool for macOS. Tap Fn to start recording and tap it again to transcribe. The app copies the result to the clipboard, then optionally pastes it into the application that was active when recording started. It works with coding assistants, terminals, editors, and other text inputs.

## Requirements and project status

- macOS 13 or later, on Apple Silicon or Intel, and a microphone.
- Karabiner-Elements for global Fn and optional DJI Mic Mini button triggers.
- Microphone permission for recording; Accessibility and event posting permissions for automatic paste and Return.

This is a `0.x` project. The repository starts from a new source snapshot; earlier development branches, tags, and release downloads have been removed. Until new packages are published, use the [source setup instructions](CONTRIBUTING.md#本地开发). Development packages marked `-dev-` are not Developer ID signed or notarized. A stable distribution must be signed and notarized separately.

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

By default, SpeekCoding pastes and presses Return. Uncheck **自动发送（粘贴时附加回车）** under **功能设置** in the menu to paste without Return. Delivery can also be configured from the CLI:

```bash
speek config --delivery-mode paste_only
speek config --delivery-mode clipboard_only
speek config --delivery-mode paste_and_send
```

Settings apply to the next recording. A recording keeps the original target application's process ID; delivery fails if that process exits. It is not redirected to whichever application later has focus.

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

The default backend is local faster-whisper with `whisper-large-v3-turbo`. Smaller models, whisper.cpp, and OpenAI-compatible transcription endpoints are supported. See the [configuration guide](README.md#转写引擎).

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

[MIT](LICENSE). Third-party runtime notices are in [packaging/THIRD_PARTY_NOTICES.md](packaging/THIRD_PARTY_NOTICES.md). Models and Karabiner-Elements are obtained separately and have their own licenses.

The hardware-trigger workflow originated from [Johnixr/dji-mic-dictation](https://github.com/Johnixr/dji-mic-dictation). SpeekCoding is not affiliated with or endorsed by Apple, DJI, Karabiner-Elements, OpenAI, or model providers.
