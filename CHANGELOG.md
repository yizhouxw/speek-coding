# Changelog

Public releases follow [Semantic Versioning](https://semver.org/). Version numbering restarts at `0.1.0` for the first public release from the cleaned source history.

## [Unreleased]

- Redesign the product site with a midnight-blue palette and clearer action contrast.

- Provide separate English and Chinese product pages with a header language switch.

- Add the GitHub Pages product introduction site.

## [0.3.0] - 2026-11-12

- Use native Fn and device-scoped DJI HID input by default, without installing Karabiner. Setup migrates owned legacy rules while preserving other remapper settings.
- Move client and HUD helpers to the SpeekCoding configuration directory.
- Input Monitoring is required. DJI mappings restore on normal exit; crash recovery runs on next launch. Sleep/wake and additional hardware/OS combinations still need field coverage.
- Release installers remain development-signed/unsigned and are not Apple-notarized.

- Separate HUD transcript text from smaller status messages below it; give errors a distinct color and longer reading time, with spacing for notch and regular screens.

- Leave ASR context empty by default to avoid instruction text leaking into recognition results. Explicit custom ASR prompts remain supported.

- Fix unresponsive status menus when enabling native Fn or DJI by removing modal guidance dialogs from the toggle actions.

- Add native DJI input with device-scoped UserKeyMapping, verified suppression before triggering, normal-exit restoration and crash-recovery records. Add read-only and bounded write/restore diagnostics; physical button/audio validation remains pending.

- Add a native Fn trigger in the app, with Input Monitoring guidance, permission recovery, legacy Fn command deduplication, and cancellation for chords/long presses. Statically link NativeInput in source and package builds; add a content-free Fn diagnostic executable. First-time setup uses native input without Karabiner.

- After a successful update, remove verified old application copies and stale Launch Services registrations while retaining downloaded models and active Python environments.

- Preserve the application icon in source-based installations and updates.

- Replace example-specific transcript rules with offline small-Chat-model correction on the Apple Silicon Qwen backend. Add a persistent Intelligent correction menu toggle and separate speech/text model download and selection menus. Preserve the original on the clipboard without auto-sending if correction fails.
- Prepare local transcription models before opening the microphone, show initialization progress, and allow Fn/HUD cancellation. Failed initialization leaves recording stopped and can be retried.

## [0.2.0] - 2026-11-06

- Add a localized License menu and a resizable, selectable, scrollable license window with OK, Close, Return, Escape, and window-close controls.
- Bundle the project license, upstream model-weight licenses, and full open-source dependency and runtime notices; collect actual package dependencies before signing and attach architecture-specific license documents to the GitHub release.

- Default Apple Silicon installations to local Qwen3-ASR-0.6B 4-bit / MLX, with live, revisable HUD transcription and final text delivery after stopping. Apple Silicon packages now require macOS 14; Intel keeps Whisper and macOS 13 support.
- Add ordered, bounded local PCM sessions, cancellation and file-transcription recovery, and bundle pinned MLX dependencies. Existing installations retain their engine until explicitly switched.

- Identify SpeekCoding's project author as yizhouxw in package metadata and copyright notices, while retaining the upstream John Yin copyright notice and clarifying attribution.

## [0.1.1] - 2026-11-04

- Localize the menu and its dialogs in English, Simplified Chinese, and Traditional Chinese. Follow macOS language preferences by default, with a persistent language selector under Feature Settings.

- Publish as a regular GitHub Release and mark it Latest. Attached `-dev-` installers remain development builds without Developer ID signing or notarization.

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
