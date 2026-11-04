# Third-party notices

## whisper.cpp

- Source: https://github.com/ggml-org/whisper.cpp
- Pinned revision: `4da27c41cebadb3cbbcd2563e9c7cbc8d84bdcad`
- License: MIT, included in [LICENSES/whisper.cpp.txt](LICENSES/whisper.cpp.txt).
- The release bundles a statically linked `whisper-cli`, including its ggml dependencies and embedded Metal code, built from this revision.
- [patches/whisper-vad-json.patch](patches/whisper-vad-json.patch) adds speech region boundaries to the CLI's JSON output using the upstream VAD accessors. This lets transcript timestamps skip a removed pause without changing recognized words.

The CLI's common audio utilities also include [miniaudio by David Reid](https://github.com/ggml-org/whisper.cpp/blob/4da27c41cebadb3cbbcd2563e9c7cbc8d84bdcad/examples/miniaudio.h) and [stb_vorbis by Sean Barrett](https://github.com/ggml-org/whisper.cpp/blob/4da27c41cebadb3cbbcd2563e9c7cbc8d84bdcad/examples/stb_vorbis.c). Both offer a public-domain/Unlicense option, selected for this distribution.

## OpenAI Whisper

- Source: https://github.com/openai/whisper
- Model: `large-v3-turbo`, converted to GGML and quantized to Q5_0.
- Distribution: https://huggingface.co/ggerganov/whisper.cpp
- File: `ggml-large-v3-turbo-q5_0.bin`
- SHA-256: `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`
- License: MIT, included in [LICENSES/Whisper.txt](LICENSES/Whisper.txt).

## Silero VAD

- Source: https://github.com/snakers4/silero-vad
- Model: `ggml-silero-v6.2.0.bin`, converted by the whisper.cpp project.
- Distribution: https://huggingface.co/ggml-org/whisper-vad
- Pinned revision: `9ffd54a1e1ee413ddf265af9913beaf518d1639b`
- SHA-256: `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`
- License: MIT, included in [LICENSES/Silero-VAD.txt](LICENSES/Silero-VAD.txt).
- Runs locally before Whisper to select speech regions. Original audio is retained.

License copies are also included inside the downloadable app at `Contents/Resources/Licenses/`.

CallToCodex uses macOS system frameworks. The Codex CLI is a user-installed prerequisite and is not redistributed inside this app. Documentation badges are provided by GitHub Actions and shields.io.
