#!/bin/bash
# fetch-models.sh: download the models MeetCapture uses. Nothing is bundled
# with the app; every file lands under ~/.whisper/models.
#
#   --whisper       ggml-medium-q5_0 (MIT) + Silero VAD for whisper.cpp   ~540 MB
#   --sherpa-es     streaming zipformer es (kroko, CC-BY-SA) + silero_vad.onnx  ~290 MB
#   --sherpa-en     streaming zipformer en (Apache-2.0)                     ~300 MB
#   --diarization   pyannote segmentation 3.0 + 3D-Speaker ERes2Net        ~ 45 MB
#   --all           everything above
#
# Downloads go to a temp file and are moved into place only when complete.
set -euo pipefail

MODELS_DIR="${MEETCAPTURE_MODELS_DIR:-$HOME/.whisper/models}"
SHERPA_DIR="$MODELS_DIR/sherpa"
HF="https://huggingface.co"
SHERPA_REL="https://github.com/k2-fsa/sherpa-onnx/releases/download"

WHISPER=0; SHERPA_ES=0; SHERPA_EN=0; DIAR=0
[ $# -gt 0 ] || { sed -n '2,12p' "$0"; exit 1; }
for arg in "$@"; do
    case "$arg" in
        --whisper) WHISPER=1 ;;
        --sherpa-es) SHERPA_ES=1 ;;
        --sherpa-en) SHERPA_EN=1 ;;
        --diarization) DIAR=1 ;;
        --all) WHISPER=1; SHERPA_ES=1; SHERPA_EN=1; DIAR=1 ;;
        *) echo "unknown flag: $arg" >&2; exit 1 ;;
    esac
done

mkdir -p "$MODELS_DIR" "$SHERPA_DIR"

fetch() { # fetch <url> <destination>
    local url="$1" dest="$2" tmp
    if [ -s "$dest" ]; then echo "  present: $dest"; return; fi
    tmp="$(mktemp "$dest.part.XXXXXX")"
    echo "  downloading $(basename "$dest")"
    if curl -fL --retry 3 --retry-delay 5 --progress-bar -o "$tmp" "$url"; then
        mv "$tmp" "$dest"
    else
        rm -f "$tmp"
        echo "  failed: $url" >&2
        return 1
    fi
}

extract() { # extract <tar.bz2> <expected dir>
    local archive="$1" dir="$2"
    if [ -d "$dir" ]; then echo "  present: $dir"; return; fi
    echo "  extracting $(basename "$archive")"
    tar -xjf "$archive" -C "$SHERPA_DIR"
    [ -d "$dir" ] || { echo "  archive did not produce $dir" >&2; return 1; }
}

if [ $WHISPER -eq 1 ]; then
    echo "whisper.cpp (MIT)"
    fetch "$HF/ggerganov/whisper.cpp/resolve/main/ggml-medium-q5_0.bin" "$MODELS_DIR/ggml-medium-q5_0.bin"
    fetch "$HF/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" "$MODELS_DIR/ggml-silero-v5.1.2.bin"
fi

if [ $SHERPA_ES -eq 1 ]; then
    echo "sherpa-onnx streaming zipformer es (kroko)"
    echo "  license: CC-BY-SA. Fine for personal and internal use; share-alike if you redistribute the weights."
    name="sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06"
    fetch "$SHERPA_REL/asr-models/$name.tar.bz2" "$SHERPA_DIR/$name.tar.bz2"
    extract "$SHERPA_DIR/$name.tar.bz2" "$SHERPA_DIR/$name"
    fetch "$SHERPA_REL/asr-models/silero_vad.onnx" "$SHERPA_DIR/silero_vad.onnx"
fi

if [ $SHERPA_EN -eq 1 ]; then
    echo "sherpa-onnx streaming zipformer en (Apache-2.0)"
    name="sherpa-onnx-streaming-zipformer-en-2023-06-26"
    fetch "$SHERPA_REL/asr-models/$name.tar.bz2" "$SHERPA_DIR/$name.tar.bz2"
    extract "$SHERPA_DIR/$name.tar.bz2" "$SHERPA_DIR/$name"
    fetch "$SHERPA_REL/asr-models/silero_vad.onnx" "$SHERPA_DIR/silero_vad.onnx"
fi

if [ $DIAR -eq 1 ]; then
    echo "speaker diarization (MIT)"
    name="sherpa-onnx-pyannote-segmentation-3-0"
    fetch "$SHERPA_REL/speaker-segmentation-models/$name.tar.bz2" "$SHERPA_DIR/$name.tar.bz2"
    extract "$SHERPA_DIR/$name.tar.bz2" "$SHERPA_DIR/$name"
    # speaker_diarize.py expects this short name.
    fetch "$SHERPA_REL/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx" \
          "$SHERPA_DIR/3dspeaker_eres2net.onnx"
fi

echo ""
echo "models in $MODELS_DIR:"
ls -1 "$MODELS_DIR" | sed 's/^/  /'
[ -d "$SHERPA_DIR" ] && ls -1 "$SHERPA_DIR" | grep -v '\.tar\.bz2$' | sed 's/^/  sherpa\//'
