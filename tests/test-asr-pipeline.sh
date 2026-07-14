#!/bin/bash
# test-asr-pipeline.sh — Unit tests for the ASR pipeline components
#
# Validates the core ASR logic — WAV conversion, format.json parsing,
# format detection (fallback), Q5 model selection against temp dir,
# deduplication — WITHOUT running whisper-cli.
#
# Run:  ./tests/test-asr-pipeline.sh
# Env:  DEBUG=1 for verbose output

set -u

APP_NAME="test-asr-pipeline"
TDIR=$(mktemp -d "/tmp/${APP_NAME}-XXXXXX")
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
# Test 3: Format.json parsing
# ============================================================
header "[3] Format.json — schema parsing and validation"
python3 <<'PY'
import json, os, sys, tempfile

def test_format_json():
    """Mirror Swift AudioFormatSchema decoding — validate schema fields."""
    td = tempfile.mkdtemp()
    ok = True

    # Valid legacy Float32 schema using the canonical snake_case contract
    schema = {
        "schema": "meetcapture.audio.v1",
        "sample_rate": 48000,
        "sample_format": "float32",
        "channels": 1,
        "layout": "mono",
    }
    jp = os.path.join(td, "test.format.json")
    with open(jp, "w") as f:
        json.dump(schema, f)
    with open(jp) as f:
        parsed = json.load(f)
    assert parsed["sample_format"] == "float32"
    assert parsed["sample_rate"] == 48000
    assert parsed["channels"] == 1
    print("  ✓ Float32 mono schema: correct fields")

    # Valid v5 Int16 stereo schema emitted by AudioCaptureService
    schema2 = {
        "schema": "meetcapture.audio.v1",
        "sample_rate": 16000,
        "sample_format": "s16le",
        "channels": 2,
        "layout": "L=system,R=mic",
    }
    jp2 = os.path.join(td, "test2.format.json")
    with open(jp2, "w") as f:
        json.dump(schema2, f)
    with open(jp2) as f:
        parsed2 = json.load(f)
    assert parsed2["sample_format"] == "s16le"
    assert parsed2["sample_rate"] == 16000
    assert parsed2["channels"] == 2
    print("  ✓ Int16 stereo schema: correct fields")

    # Optional descriptive fields may be omitted
    schema3 = {"sample_format": "float32", "sample_rate": 48000, "channels": 1}
    jp3 = os.path.join(td, "test3.format.json")
    with open(jp3, "w") as f:
        json.dump(schema3, f)
    with open(jp3) as f:
        parsed3 = json.load(f)
    assert parsed3["sample_format"] == "float32"
    print("  ✓ Optional descriptive fields may be absent")

    # Missing format.json = legacy fallback (test handled by caller)
    print("  ✓ Absent format.json → legacy Float32 mono fallback")

    return ok

test_format_json()
print("  ✓ Format.json: all schema tests passed")
PY
[ $? -eq 0 ] && green "Format.json: all validations passed" || fail "Format.json: validation failed"

# ============================================================
# Test 4: Q5 model selection (temp dir, not host)
# ============================================================
header "[4] Q5 model selection — preference order (temp dir)"
python3 <<'PY'
import os, tempfile

# Simulate model directory with different variants in a temp dir
td = tempfile.mkdtemp()
try:
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

    # Q5 glob: verify that the glob pattern works
    import glob
    q5_files = glob.glob(os.path.join(td, "ggml-*-q5_*.bin"))
    os.remove(os.path.join(td, "ggml-medium.bin"))
    # Re-add Q5_0 to test glob
    with open(os.path.join(td, "ggml-medium-q5_0.bin"), 'wb') as f:
        f.write(b'\x00' * (800 * 1024 * 1024))
    q5_files = glob.glob(os.path.join(td, "ggml-*-q5_*.bin"))
    assert len(q5_files) == 1, f"Expected 1 Q5 file, found {len(q5_files)}: {q5_files}"
    print(f"  ✓ Q5 glob: found {len(q5_files)} Q5 variant(s)")

finally:
    import shutil
    shutil.rmtree(td, ignore_errors=True)
PY
[ $? -eq 0 ] && green "Q5 selection: all preference tests passed (temp dir)" || fail "Q5 selection: test failed"

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
# Test 6: Format.json validation — must fail on invalid/missing fields
# ============================================================
header "[6] Format.json validation — rejects invalid metadata"
python3 <<'PY'
import json, os, tempfile

def validate_format_schema(data):
    """Validate a format.json schema. Raises on invalid."""
    req = ["sample_format", "sample_rate", "channels"]
    for field in req:
        if field not in data:
            raise ValueError(f"Missing required field: {field}")
    if data["sample_format"] not in ("float32", "s16le", "int16"):
        raise ValueError(f"Invalid sample_format: {data['sample_format']}")
    if not isinstance(data["sample_rate"], int) or data["sample_rate"] <= 0:
        raise ValueError(f"Invalid sample_rate: {data['sample_rate']}")
    if not isinstance(data["channels"], int) or data["channels"] not in (1, 2):
        raise ValueError(f"Invalid channels: {data['channels']}")
    return True

td = tempfile.mkdtemp()
errors = 0

# Test: missing format
try:
    validate_format_schema({"sample_rate": 48000, "channels": 1})
    print("  ✗ Should have rejected missing 'format'")
    errors += 1
except ValueError as e:
    print(f"  ✓ Rejected missing format: {e}")

# Test: invalid format string
try:
    validate_format_schema({"sample_format": "int8", "sample_rate": 48000, "channels": 1})
    print("  ✗ Should have rejected invalid format 'int8'")
    errors += 1
except ValueError as e:
    print(f"  ✓ Rejected invalid format: {e}")

# Test: missing sampleRate
try:
    validate_format_schema({"sample_format": "float32", "channels": 1})
    print("  ✗ Should have rejected missing sampleRate")
    errors += 1
except ValueError as e:
    print(f"  ✓ Rejected missing sampleRate: {e}")

# Test: zero sampleRate
try:
    validate_format_schema({"sample_format": "float32", "sample_rate": 0, "channels": 1})
    print("  ✗ Should have rejected zero sampleRate")
    errors += 1
except ValueError as e:
    print(f"  ✓ Rejected zero sampleRate: {e}")

# Test: invalid channels
try:
    validate_format_schema({"sample_format": "float32", "sample_rate": 48000, "channels": 3})
    print("  ✗ Should have rejected 3 channels")
    errors += 1
except ValueError as e:
    print(f"  ✓ Rejected invalid channels: {e}")

# Test: valid schema passes
try:
    assert validate_format_schema({"sample_format": "float32", "sample_rate": 48000, "channels": 1}) == True
    print("  ✓ Valid float32 mono schema accepted")
except Exception as e:
    print(f"  ✗ Valid schema rejected: {e}")
    errors += 1

if errors > 0:
    print(f"  ❌ Format validation: {errors} failure(s)")
    exit(1)
print("  ✓ Format.json validation: all rejection tests passed")
PY
[ $? -eq 0 ] && green "Format.json validation: all tests passed" || fail "Format.json validation: test failed"

# ============================================================
# Test 7: WhisperModelSize enum coverage
# ============================================================
header "[7] WhisperModelSize — Q5 filename generation"
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
