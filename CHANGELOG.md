# Changelog

Public releases follow [Semantic Versioning](https://semver.org/). Version numbering restarts at `0.1.0` for the first public release from the cleaned source history.

## [0.1.0] - 2026-11-04

- First public source release under the MIT license, with an English default README and a complete Chinese guide.
- Native macOS menu bar app for recording, local-first transcription, clipboard delivery, and targeted paste to the application active when recording started.
- Local faster-whisper runtime, optional whisper.cpp and OpenAI-compatible transcription endpoints, and model download/loading feedback with cancellation.
- Standalone Fn tap and optional DJI Mic Mini button triggers through Karabiner-Elements. Fn combinations such as Fn+F12 retain their normal behavior.
- Microphone selection, permission guidance, recording HUD, and an auto-send setting that controls whether pasting is followed by Return.
- Authenticated per-user IPC, loopback-only local ASR, temporary recording cleanup, and stable local development signing.
- Standalone NativeInput experimental Swift library and state tests; it is not integrated into the app or a replacement for Karabiner.
- Apple Silicon and Intel development installers with SHA-256 checksums. These installers are unsigned and unnotarized; the app uses ad-hoc signing on clean CI runners. This release is marked as a development pre-release.

### Known limitations

- macOS 13 or later is required. Passing tests and builds does not establish compatibility with every keyboard, DJI firmware, or macOS permission configuration.
- Whisper model weights are downloaded separately on first use and are not included in the installers.
- Development packages do not have Developer ID distribution signing or notarization. macOS may block installation or launch, and upgrades may require permissions to be granted again.
- Earlier private version numbers, tags, and release downloads are not part of this public release series. Existing development installations with a different signing identity require separate upgrade validation.
