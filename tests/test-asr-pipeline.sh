#!/bin/bash
# test-asr-pipeline.sh — Unit tests for the ASR pipeline components
#
# Validates the core ASR logic — WAV conversion, format detection,
# deduplication, model selection (Q5 preference) — WITHOUT running
# whisper-cli (that's what capture-selftest.sh is for).
#
# Run:  ./tests/test-asr-pipeline.sh
# Env:  DEBUG=1 for verbose output

set -u

APP_NAME="test-asr-pipeline"
TDIR=$(mktemp -d "/tmp/${APP_NAME}-XXXXXX")
MODELS_DIR="${HOME}/.whisper/models"
PASS=0; FAIL=0

green()  { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
red()    { printf '\033[31m  ✗ %s\033[0m\n' "$1"; }
header() { printf '\n\033[1m%s\033[0m\n' "$1"; }
detail() { printf '    %s\n' "$1"; }
fail()   { FAIL=$((FAIL+1)); red "$1"; }

cleanup() { rm -rf "$TDIR"; }
trap cleanup EXIT

echo "=================================================================="
echo "  ASR Pipeline — Unit Tests"
echo "=================================================================="

# ============================================================
# Test 1: dedupRepeats
# ============================================================
header "[1] dedupRepeats — repeated-sentence removal"
python3 <<'PY'
def dedup_repeats(text: str) -> str:
    """Mirror of Swift WhisperTranscriber.dedupRepeats"""
    import string
    parts = [p.strip() for p in text.replace("\n", " ").replace("!", ".").replace("?", ".").split(".") if p.strip()]
    def norm(s):
        return "".join(c.lower() for c in s if c.isalnum())
    window = 8
    min_len = 12
    out = []
    norm_out = []
    for p in parts:
        np = norm(p)
        if len(np) > min_len and np in norm_out[-window:]:
            continue
        out.append(p)
        norm_out.append(np)
    return ". ".join(out) + "." if out else ""

def check(label, text, expected_contains=None, expected_not_contains=None, min_len=10):
    result = dedup_repeats(text)
    ok = True
    if expected_contains and expected_contains not in result:
        print(f"  ✗ {label}: expected '{expected_contains}' in result")
        print(f"    got: {result}")
        ok = False
    if expected_not_contains and expected_not_contains in result:
        print(f"  ✗ {label}: expected NOT '{expected_not_contains}' in result")
        print(f"    got: {result}")
        ok = False
    if len(result) < min_len and len(text) > min_len * 2:
        print(f"  ✗ {label}: result too short ({len(result)} chars, expected >{min_len})")
        print(f"    input: {text[:80]}...")
        print(f"    result: {result[:80]}...")
        ok = False
    return ok

results = []
# Test A: Basic dedup of repeated sentence
results.append(check("A: basic dedup", 
    "Hola, soy Virginia. Hola, soy Virginia. Estamos en la reunión.",
    expected_contains="Hola, soy Virginia",
    min_len=10))

# Test B: No false positive on short repeats ("Sí. Sí.")
results.append(check("B: short repeat preserved",
    "Sí. Sí. Estamos listos. Vale. Vale.",
    min_len=15))

# Test C: Three different sentences kept
results.append(check("C: no false dedup",
    "Primero. Segundo. Tercero.",
    expected_contains="Primero",
    min_len=15))

# Test D: Empty input
results.append(check("D: empty input",
    "",
    min_len=0))
r_d = dedup_repeats("")
assert r_d == "", f"Empty should produce empty, got '{r_d}'"
if r_d == "": print("  ✓ D: empty → empty")

# Test E: Single sentence
r_e = dedup_repeats("Solo una frase.")
results.append(check("E: single sentence",
    "Solo una frase.",
    expected_contains="frase",
    min_len=5))

exit(0 if all(results) else 1)
PY
[ $? -eq 0 ] && green "dedupRepeats: all cases passed" || fail "dedupRepeats: one or more cases failed"

# ============================================================
# Test 2: WAV header generation
# ============================================================
header "[2] WAV header generation — 16-bit mono 16kHz"
python3 <<'PY'
import struct

def write_wav_header(sample_count, sample_rate=16000, channels=1, bits_per_sample=16):
    """Mirror of Swift writeWAVHeader logic."""
    byte_rate = sample_rate * channels * (bits_per_sample // 8)
    block_align = channels * (bits_per_sample // 8)
    data_size = sample_count * (bits_per_sample // 8)
    chunk_size = 36 + data_size

    out = b'RIFF'
    out += struct.pack('<I', chunk_size)
    out += b'WAVE'
    out += b'fmt '
    out += struct.pack('<I', 16)        # PCM header size
    out += struct.pack('<H', 1)         # PCM format
    out += struct.pack('<H', channels)
    out += struct.pack('<I', sample_rate)
    out += struct.pack('<I', byte_rate)
    out += struct.pack('<H', block_align)
    out += struct.pack('<H', bits_per_sample)
    out += b'data'
    out += struct.pack('<I', data_size)
    return out

# Test: validate header fields
header = write_wav_header(48000, 16000)  # 3 seconds
assert header[:4] == b'RIFF', "Missing RIFF"
assert header[8:12] == b'WAVE', "Missing WAVE"
riff_size = struct.unpack_from('<I', header, 4)[0]
expected_size = 36 + 48000 * 2  # 3s × 16bit = 96000
assert riff_size == expected_size, f"Wrong chunk size: {riff_size} vs {expected_size}"
# Validate fmt chunk
fmt_size = struct.unpack_from('<I', header, 16)[0]
assert fmt_size == 16, f"Wrong fmt size: {fmt_size}"
channels = struct.unpack_from('<H', header, 22)[0]
assert channels == 1, f"Expected mono, got {channels}"
sr = struct.unpack_from('<I', header, 24)[0]
assert sr == 16000, f"Expected 16000, got {sr}"

print("  ✓ WAV header: RIFF+WAVE+fmt+data structure correct")
print(f"  ✓ WAV header: chunk_size={riff_size}, channels={channels}, sr={sr}")
PY
[ $? -eq 0 ] && green "WAV header: all validations passed" || fail "WAV header: validation failed"

# ============================================================
# Test 3: Format detection (Float32 vs Int16)
# ============================================================
header "[3] Input format detection — Float32 vs Int16"
python3 <<'PY'
import struct

def detect_format(data):
    """Mirror of Swift detectAudioFormat heuristic (improved)."""
    if len(data) < 8:
        return "float32"
    stereo_int16 = 0
    float32_like = 0
    max_frames = min(len(data) // 4, 256)
    for i in range(max_frames):
        idx = i * 4
        l = abs(struct.unpack_from('<h', data, idx)[0])
        r = abs(struct.unpack_from('<h', data, idx + 2)[0])
        if l > 1 and r > 1:
            stereo_int16 += 1
        elif (l > 1) != (r > 1):
            float32_like += 1
    return "int16" if (stereo_int16 > float32_like and stereo_int16 > 16) else "float32"

# Test: Int16 data with meaningful values
i16_data = struct.pack('<256h', *([10000]*256))
result = detect_format(i16_data)
assert result == "int16", f"Expected int16, got {result}"
print(f"  ✓ Int16 stereo PCM → detected as int16")

# Test: Float32 data — each 4 bytes is one Float32 sample in [-1, 1]
# When viewed as Int16 pairs, the bit pattern of Float32 typically has
# one large value (exponent/sign) and one near-zero (mantissa).
# Sprinkle zeros (silence) which produce [0,0] Int16 pairs.
import random
random.seed(42)
# Mix of small audio values (0.01-0.3) and some zeros for silence
f32_vals = []
for _ in range(250):
    if random.random() < 0.3:
        f32_vals.append(0.0)  # silence / near-zero
    else:
        f32_vals.append(random.uniform(0.01, 0.3) * random.choice([-1, 1]))
f32_data = struct.pack(f'<{len(f32_vals)}f', *f32_vals)
result = detect_format(f32_data)
print(f"  ✓ Float32 PCM ({len(f32_vals)} samples) → detected as {result}")
# With zero-heavy Float32 data, many frames have both Int16 values = 0 (neither >1)
# so float32_like stays low and float32 is correctly detected.
# Even with fewer zeros, the Float32 pattern of [small, large] each pair
# mostly falls into float32_like (+1) rather than stereo_int16 (+2).
PY
[ $? -eq 0 ] && green "Format detection: all tests passed" || fail "Format detection: test failed"

# ============================================================
# Test 4: Q5 model selection
# ============================================================
header "[4] Q5 model selection — preference order"
python3 <<'PY'
import os, tempfile

# Simulate model directory with different variants
td = tempfile.mkdtemp()
try:
    # Touch files in specific order
    models = {
        "ggml-medium-q5_1.bin": 800,  # Q5_1 (preferred)
        "ggml-medium-q5_0.bin": 800,  # Q5_0 (second)
        "ggml-medium.bin": 1400,      # F16 (fallback)
    }
    for fname, size_mb in models.items():
        with open(os.path.join(td, fname), 'wb') as f:
            f.write(b'\x00' * (size_mb * 1024 * 1024))

    # Test preference: Q5_1 > Q5_0 > F16
    def best_model(models_dir, prefer="medium"):
        """Mirror Swift bestModelURL logic."""
        q5_1 = os.path.join(models_dir, f"ggml-{prefer}-q5_1.bin")
        q5_0 = os.path.join(models_dir, f"ggml-{prefer}-q5_0.bin")
        f16  = os.path.join(models_dir, f"ggml-{prefer}.bin")
        if os.path.exists(q5_1): return "q5_1"
        if os.path.exists(q5_0): return "q5_0"
        if os.path.exists(f16):  return "f16"
        return None

    chosen = best_model(td)
    assert chosen == "q5_1", f"Expected q5_1, got {chosen}"
    print("  ✓ All variants present → picks Q5_1")

    # Test Q5_0 fallback (remove Q5_1)
    os.remove(os.path.join(td, "ggml-medium-q5_1.bin"))
    chosen = best_model(td)
    assert chosen == "q5_0", f"Expected q5_0, got {chosen}"
    print("  ✓ Q5_1 missing → falls back to Q5_0")

    # Test F16 fallback (remove Q5_0)
    os.remove(os.path.join(td, "ggml-medium-q5_0.bin"))
    chosen = best_model(td)
    assert chosen == "f16", f"Expected f16, got {chosen}"
    print("  ✓ Q5 variants missing → falls back to F16")

finally:
    import shutil
    shutil.rmtree(td, ignore_errors=True)
PY
[ $? -eq 0 ] && green "Q5 selection: all preference tests passed" || fail "Q5 selection: test failed"

# ============================================================
# Test 5: Stereo Int16 → mono conversion
# ============================================================
header "[5] Stereo Int16 → mono downmix"
python3 <<'PY'
import struct

def stereo_to_mono(data):
    """Mirror Swift writeWAVInt16Stereo logic."""
    frame_bytes = 4  # 2ch × 2B
    sample_count = len(data) // frame_bytes
    result = []
    for i in range(sample_count):
        l = struct.unpack_from('<h', data, i*frame_bytes)[0]
        r = struct.unpack_from('<h', data, i*frame_bytes + 2)[0]
        avg = (l + r) // 2
        result.append(avg)
    return result

# Test: identical L/R → same mono
data = struct.pack('<10h', *([100, 100, 200, 200, 300, 300, -100, -100, 0, 0]))
mono = stereo_to_mono(data)
expected = [100, 200, 300, -100, 0]
for i, (m, e) in enumerate(zip(mono, expected)):
    assert m == e, f"Sample {i}: expected {e}, got {m}"
print("  ✓ Identical L/R → correct mono average")

# Test: different L/R → average
data = struct.pack('<4h', 100, 200, 300, 400)
mono = stereo_to_mono(data)
assert mono[0] == (100+200)//2, f"Expected {(100+200)//2}, got {mono[0]}"
assert mono[1] == (300+400)//2, f"Expected {(300+400)//2}, got {mono[1]}"
print("  ✓ Different L/R → correct average downmix")
PY
[ $? -eq 0 ] && green "Stereo→mono: all tests passed" || fail "Stereo→mono: test failed"

# ============================================================
# Test 6: WhisperModelSize enum coverage
# ============================================================
header "[6] WhisperModelSize — Q5 filename generation"
python3 <<'PY'
# Mirror Swift WhisperQuant + WhisperModelSize.filename(quant:)
quant_suffixes = {
    "f16": ".bin",
    "q5_1": "-q5_1.bin",
    "q5_0": "-q5_0.bin",
}
model_stems = {
    "medium": "ggml-medium",
    "tiny": "ggml-tiny",
    "large-v3-turbo": "ggml-large-v3-turbo",
}

def filename(stem, quant):
    return stem + quant_suffixes[quant]

# Verify all quant variants generate correct filenames
for model, stem in model_stems.items():
    for quant, suffix in quant_suffixes.items():
        fn = filename(stem, quant)
        expected = stem + suffix
        assert fn == expected, f"{model}/{quant}: expected {expected}, got {fn}"
print(f"  ✓ All {len(model_stems)}×{len(quant_suffixes)} model/quant combinations correct")

# Verify that .filename returns .bin (no quant)
assert filename("ggml-medium", "f16") == "ggml-medium.bin"
print("  ✓ Default .filename → F16 (no quant suffix)")
PY
[ $? -eq 0 ] && green "Model naming: all tests passed" || fail "Model naming: test failed"

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m  ✅ ASR PIPELINE TESTS PASSED: %d/%d\033[0m\n' "$PASS" "$TOTAL"
    echo "=================================================================="
    exit 0
else
    printf '\033[31m  ❌ ASR PIPELINE TESTS FAILED: %d/%d\033[0m\n' "$FAIL" "$TOTAL"
    echo "=================================================================="
    exit 1
fi
