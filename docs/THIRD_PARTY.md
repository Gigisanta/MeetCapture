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
