#!/bin/bash
# setup-venv.sh: create ~/.meetcapture/venv with sherpa-onnx (speaker
# labels) and print the interpreter
# path the app will pick up automatically.
#   VENV_DIR   override the destination (default ~/.meetcapture/venv)
#   PYTHON     override the base interpreter (default: Homebrew python3.11, else python3)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DIR="${VENV_DIR:-$HOME/.meetcapture/venv}"

if [ -z "${PYTHON:-}" ]; then
    for candidate in "$(brew --prefix 2>/dev/null)/bin/python3.11" /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11; do
        if [ -x "$candidate" ]; then PYTHON="$candidate"; break; fi
    done
    PYTHON="${PYTHON:-$(command -v python3)}"
fi

echo "base interpreter: $PYTHON ($("$PYTHON" --version 2>&1))"
mkdir -p "$(dirname "$VENV_DIR")"
chmod 700 "$(dirname "$VENV_DIR")"
if [ ! -x "$VENV_DIR/bin/python3" ]; then
    "$PYTHON" -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/python3" -m pip install --quiet --upgrade pip
"$VENV_DIR/bin/python3" -m pip install --quiet -r "$ROOT/requirements.txt"
"$VENV_DIR/bin/python3" -B -c "import sherpa_onnx, numpy; print('sherpa-onnx', sherpa_onnx.__version__, 'numpy', numpy.__version__)"

echo ""
echo "python: $VENV_DIR/bin/python3"
echo "MeetCapture resolves this path on its own (Settings › ASR shows 'fuente: venv')."
echo "Models: scripts/fetch-models.sh --diarization"
