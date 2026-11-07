# SpeekCoding

English · [简体中文](README.zh-CN.md)

**Speak your next coding task. Put it straight into your editor.**

SpeekCoding brings local voice input to macOS. Focus a text field in Codex, Claude Code, Cursor, a terminal, or another app. Tap **Fn**, speak, and tap again to finish. SpeekCoding copies the transcript and can paste it into the app where you started recording, with an optional Return to send it.

[Download for macOS](https://github.com/yizhouxw/speek-coding/releases/latest) · [Quick start](#quick-start) · [Usage guide (中文)](docs/USAGE.zh-CN.md) · [Get help](SUPPORT.md)

## Why SpeekCoding

- **See words while you speak.** On Apple Silicon, live transcription updates in the floating HUD and revises the draft with more context. Stopping finalizes the text; transcription is already underway while you talk.
- **Keep speech on your Mac.** The default engine processes audio locally, with no ASR API key or cloud transcription subscription required. After the model is downloaded, local transcription works offline.
- **Use your existing tools.** Dictate a prompt, describe a bug, or write a message wherever pasting is supported. Choose automatic paste and Return, paste only, or clipboard only.
- **A shortcut within reach.** Tap Fn to start and stop, or use an optional DJI Mic Mini button. Fn combinations keep their normal behavior. Global triggers use Karabiner-Elements.
- **Built for Apple Silicon, with Intel support.** Qwen3-ASR-0.6B uses 4-bit weights and MLX acceleration on Apple Silicon. Intel uses local faster-whisper with transcription after recording stops.
- **Stay in your flow.** A native menu bar app provides microphone selection, recording feedback, cancellation, and English, Simplified Chinese, and Traditional Chinese menus. Release installers include the runtime, so users do not need Node.js, Python, Homebrew, or Xcode.

## Quick start

**Requires:** Apple Silicon with macOS 14+, or Intel with macOS 13+, a microphone, and [Karabiner-Elements](https://karabiner-elements.pqrs.org/) for Fn / DJI triggers.

1. Download the matching `.pkg` from [Releases](https://github.com/yizhouxw/speek-coding/releases/latest): `arm64` for Apple Silicon, `x86_64` for Intel. Install it and open **SpeekCoding** from Applications.
2. Install and open Karabiner-Elements, then complete its system authorization. SpeekCoding's menu can guide you to its official installer.
3. Open Terminal and configure the keyboard trigger:

   ```bash
   speek setup --trigger-mode keyboard
   speek doctor
   ```

4. In the menu bar, select your microphone and grant SpeekCoding microphone permission. Automatic paste and Return also require Accessibility and event posting permissions.
5. Focus a text input. **Tap Fn → speak → tap Fn again.** The first use downloads and loads the model; later sessions reuse cached weights.

> Current `-dev-` installers are not Developer ID signed or notarized. macOS may block installation or launch; read the release notes before installing. Models are downloaded separately.

## Make it fit your workflow

**Review before sending.** Automatic paste and Return is enabled by default. Uncheck **Feature Settings → Auto-send** to paste without sending, or select a delivery mode:

```bash
speek config --delivery-mode paste_only
speek config --delivery-mode clipboard_only
speek config --delivery-mode paste_and_send
```

**Use a wireless button.** Connect the DJI Mic Mini receiver and configure its transmitter button:

```bash
speek setup --trigger-mode keyboard+dji --input-device "DJI Mic Mini"
```

**Choose your language and microphone.** Both are available in the menu bar. Menus follow macOS by default; changing the menu language does not change the recognition language.

**Cancel whenever needed.** Use Cancel in the recording HUD or `speek cancel`. Pressing Fn while transcription or model preparation is in progress also cancels. During recording, Fn stops and finalizes.

## Local transcription

New Apple Silicon installations default to **Qwen3-ASR-0.6B, 4-bit / MLX**, with live, revisable drafts. Finalization still takes processing time, which varies with the Mac and recording length. Intel defaults to **faster-whisper**. Local Whisper, whisper.cpp, and OpenAI-compatible file transcription services are also configurable.

Existing installations retain their configured engine. To switch to Qwen / MLX on Apple Silicon after updating:

```bash
speek config --asr-backend qwen-mlx --asr-model mlx-community/Qwen3-ASR-0.6B-4bit
speek asr-install
speek restart
```

For engine options, devices, delivery settings, and commands, see the [usage guide (中文)](docs/USAGE.zh-CN.md). `speek status` shows current status; `speek doctor` helps diagnose setup issues. `speek update` refreshes the installed integration from the CLI version being run; download a new installer to upgrade the release.

## Privacy

Default transcription stays on the loopback interface. First-use model downloads and optional Karabiner downloads require a network connection. There is no built-in usage analytics or recording upload service. Choosing a remote ASR endpoint sends audio to that provider.

Ordinary temporary recordings are cleaned up after a session. Explicit test recordings, cached models, and clipboard contents are retained. See [SECURITY.md](SECURITY.md) for details.

## Documentation and development

- [Usage and configuration (中文)](docs/USAGE.zh-CN.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md) · [Support](SUPPORT.md)
- [Source installation and contributing](CONTRIBUTING.md)
- [Architecture](docs/ARCHITECTURE.md) · [Changelog](CHANGELOG.md)

Source development requires macOS, Node.js 20.12+, Python 3.12, and Xcode Command Line Tools. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and checks.

## License and acknowledgments

[MIT](LICENSE). Project author: [yizhouxw](https://github.com/yizhouxw). The hardware-trigger workflow originated from [Johnixr/dji-mic-dictation](https://github.com/Johnixr/dji-mic-dictation); the upstream John Yin copyright notice is retained. [Third-party notices](packaging/THIRD_PARTY_NOTICES.md).

SpeekCoding is not affiliated with or endorsed by Apple, DJI, Karabiner-Elements, OpenAI, or model providers.

When the local model is not ready, pressing the recording key shows model initialization before the microphone opens. Recording starts once initialization succeeds; press Fn or the HUD cancel button to cancel. whisper.cpp performs a silent warm-up once per service session to prime system caches; its CLI still loads model weights for each transcription.
