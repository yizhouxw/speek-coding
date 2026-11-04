# Third-party notices

SpeekCoding's self-contained macOS package includes these third-party runtimes and libraries:

- Node.js, licensed under the MIT license and additional licenses listed in the bundled `Node.js-LICENSE` file.
- CPython from python-build-standalone. The Python license is bundled with the runtime at `runtime/python/lib/python3.12/LICENSE.txt`; python-build-standalone is distributed under MPL-2.0.
- faster-whisper and its Python dependencies. Their license files are preserved in the corresponding `*.dist-info` directories under `runtime/python/lib/python3.12/site-packages`.
- `@clack/prompts` and its npm dependencies. Their package metadata and license files are preserved under `node_modules` in the application resources.

The package build keeps the original license files next to the redistributed binaries. Refer to those files for the complete terms and copyright notices.

Karabiner-Elements and Whisper model weights are not included in the package. They are downloaded or installed separately and remain subject to their own licenses and terms. Karabiner-Elements is required for the current Fn and DJI trigger workflow. The hardware-trigger workflow credits the MIT-licensed `Johnixr/dji-mic-dictation` project; see the repository README for the source link.
