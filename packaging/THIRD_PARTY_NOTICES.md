# Third-party notices

SpeekCoding's project author is yizhouxw. The hardware-trigger workflow originated from [Johnixr/dji-mic-dictation](https://github.com/Johnixr/dji-mic-dictation), whose MIT license carries `Copyright (c) 2026 John Yin`. That upstream copyright notice is retained alongside SpeekCoding's copyright notice in the root `LICENSE`; the package author field identifies the SpeekCoding project author rather than the upstream author.

SpeekCoding's self-contained macOS package includes these third-party runtimes and libraries:

- Node.js, licensed under the MIT license and additional licenses listed in the bundled `Node.js-LICENSE` file.
- CPython from python-build-standalone. The Python license is bundled with the runtime at `runtime/python/lib/python3.12/LICENSE.txt`; python-build-standalone is distributed under MPL-2.0.
- On Apple Silicon, mlx-qwen3-asr (Apache-2.0), MLX and its Metal runtime (MIT), and their dependencies. License files are retained in the corresponding `*.dist-info` directories.
- faster-whisper and its Python dependencies. Their license files are preserved in the corresponding `*.dist-info` directories under `runtime/python/lib/python3.12/site-packages`.
- `@clack/prompts` and its npm dependencies. Their package metadata and license files are preserved under `node_modules` in the application resources.

The package build keeps the original license files next to the redistributed binaries. Refer to those files for the complete terms and copyright notices.

Karabiner-Elements and Qwen / Whisper model weights are not included in the package. They are downloaded or installed separately and remain subject to their own licenses and terms. Karabiner-Elements is required for the current Fn and DJI trigger workflow. The hardware-trigger workflow credits the MIT-licensed `Johnixr/dji-mic-dictation` project; see the repository README for the source link.

The default Qwen3-ASR-0.6B 4-bit weights are distributed separately by [mlx-community](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit), converted from [Qwen/Qwen3-ASR-0.6B](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), under Apache-2.0. The [MLX runtime adapter](https://github.com/moona3k/mlx-qwen3-asr) is a community implementation.
