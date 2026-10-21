# Third-party code and models

MeetCapture's own code is MIT (see `LICENSE`). Speech recognition and
diarization come from the components below. No model weights are stored in
this repository or copied into the app bundle: FluidAudio downloads them from
Hugging Face on first use into `~/Library/Application Support/FluidAudio/`
(network is needed once), and they stay on the Mac.

| Component | Used for | License | Source |
| --- | --- | --- | --- |
| FluidAudio | Swift package: Core ML inference on the Neural Engine, model download, offline diarizer | Apache-2.0 | [github.com/FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio), pinned by revision in `Package.swift` |
| NVIDIA Parakeet TDT 0.6B v3, "ultra" post-training | Transcription (`AsrModelVersion.ultra`) | CC-BY-4.0 | Core ML build [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml), from [moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra), a post-training of [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) |
| pyannote speaker-diarization community-1 | Segmentation and speaker embeddings for the offline diarizer | CC-BY-4.0 | Core ML build [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml) (its `NOTICE.md` scopes CC-BY-4.0 to the community-1 artifacts), from [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) |
| WhisperKit / Argmax OSS 1.1.1 | Research-only local Whisper large-v3 adapter; never selected by production controls | MIT; vendored swift-transformers code is Apache-2.0 | [v1.1.1](https://github.com/argmaxinc/argmax-oss-swift/tree/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4), commit `1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4`; [upstream notices](https://github.com/argmaxinc/argmax-oss-swift/blob/1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4/NOTICES) |
| Whisper large-v3 compressed Core ML conversion, 947MB folder | Research-only word-aligned transcription, 32 encoder and 32 decoder layers | MIT according to the conversion repository card | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-large-v3_947MB), revision `0f63a7800b00dd0226abd051b906c246e1907482` |
| OpenAI Whisper large-v3 tokenizer | Local-only tokenizer files for that experimental conversion | Apache-2.0 according to its repository card | [openai/whisper-large-v3](https://huggingface.co/openai/whisper-large-v3/tree/06f233fe06e710322aca913c1bc4249a0d71fce1), revision `06f233fe06e710322aca913c1bc4249a0d71fce1` |

The license tags above were read from the Hugging Face model cards and the
FluidAudio checkout at the pinned revision; re-check them when the revision
or `AsrModelVersion` changes.

## Attribution

CC-BY-4.0 requires crediting the authors, linking the license
(https://creativecommons.org/licenses/by/4.0/) and saying whether the models
were changed. MeetCapture uses the Core ML conversions unmodified and credits
them in Settings › Acerca de:

> Modelos: NVIDIA Parakeet TDT y pyannote, vía FluidAudio (CC-BY-4.0).

Anyone who redistributes the weights themselves (for example, bundling them in
an app) must carry the model cards' attribution and notices with them.

## WhisperKit experiment: offline artifacts and notices

This checkout pins the **exact v1.1.1 commit**, not a moving branch or latest
model. Its Swift 6.2 package manifest uses unsafe library-evolution flags, so
`Package.swift` expresses the immutable release commit as a revision requirement.
`Package.resolved` also freezes swift-argument-parser 1.8.2 at
`6a52f3251125d74daf04fcbd5e6f08a75d074382`; that CLI dependency is not linked into
the WhisperKit product. The SDK vendors modified swift-transformers 1.1.6
(`573e5c9036c2f136b3a8a071da8e8907322403d0`); its Apache-2.0 copyright and
license are retained in the SDK's `NOTICES`.

Prepare model, tokenizer and source notices into a **new** directory:

```bash
python3 qa/asr_whisper_model.py prepare --out /tmp/mc-whisper-large-v3-pinned
```

The utility itself invokes `bin/system/resource_guard.py run --class cpu-heavy
--ram-gib 16 --disk-gib 12 --run-seconds 3600`; do not bypass a refusal or reduce
those budgets. It downloads 950,908,633 pinned bytes, checking every file's
size and SHA-256, and writes `whisperkit-artifact.json` only when complete.
Failed partial artifacts are not reusable models. A separate checkout can pass
`--resource-guard /absolute/path/to/bin/system/resource_guard.py`.

Set `MEETCAPTURE_QA_ENGINE=whisperkit` and
`MEETCAPTURE_QA_WHISPER_MODEL_DIR=/tmp/mc-whisper-large-v3-pinned` on the isolated
QA real-check/prefetch process. The variable names the **artifact root**, not its
`openai_whisper-large-v3_947MB` child. The adapter requires the frozen manifest
inventory (`d13c4c7e93c175b29a439aa4e0d54811facb80d9ea3d0044ed9f0d74d4d1d9ef`)
and rehashes all asset bytes before each model load. It never asks the SDK to
download, and injects the tokenizer using the local-only factory before loading
models. This avoids the SDK's otherwise-networked tokenizer fallback even when
`WhisperKitConfig.download` is false. The local protocol wrapper's word-splitting
helpers are adapted from v1.1.1 `Models.swift`; BPE and text decoding remain the
SDK implementations. The wrapper verifies special tokens and the actual SDK
tokenization of the frozen prompt instead of substituting another tokenizer.

`MEETCAPTURE_QA_WHISPER_PROMPT=1` is the separate fixed-context arm. Its full
text is `Reunión de trabajo. Terminología: API, PostgreSQL, TypeScript, GitHub, Vercel.`
(UTF-8 SHA-256 `d5ead012416bc45c1a09739cdf22a8f8c55012bf7351a50fa512d4c6752ece53`).
It is 25 content tokens without special tokens; the full token sequence is in
the recognizer identity, invocation trace and artifact manifest. Loading fails
if the actual SDK tokenizer disagrees or exceeds 64 tokens. The other arm has
no prompt tokens or prefix tokens. Full effective decoder options and fallback
temperatures are serialized, and the complete raw SDK result is retained in
opt-in QA traces before conversion to real `WordTiming` segments.

For array inputs, a narrow subclass retains the SDK's VAD chunker, worker
batching and offset merger, but traces every chunk's complete result/error and
throws failures before merging. Stock 1.1.1 otherwise logs and drops failed
VAD chunks. The incremental file path already propagates chunk errors.

Core ML is configured with mel `cpuOnly` and encoder/decoder
`cpuAndNeuralEngine`. These are requested compute units, not measured physical
placement. File transcription explicitly selects the SDK's bounded incremental
loader (120-second staging, two buffered chunks) with VAD. Actual timestamps
are never interpolated; nonempty SDK text without word alignment is an explicit
failure. The conversion's pinned config declares 32 layers; its `torch_dtype`
field does **not** establish the compressed Core ML weights' precision. Do not
describe this asset as FP16. macOS 14.4 compatibility remains unverified on the
macOS 26 experiment host; upstream 1.1.1 removed macOS 14 from its CI.

The preparer retains, unmodified and checksummed, the Core ML repository card,
the tokenizer repository card, the SDK `LICENSE`, and its complete `NOTICES`
(including the Apache-2.0 text and Hugging Face copyright) under `notices/`.
The Core ML conversion is used unmodified. The local-only wrapper and strict
chunk-error propagation adaptations carry the following Argmax license notice:

```text
MIT License

Copyright (c) 2024 argmax, inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
