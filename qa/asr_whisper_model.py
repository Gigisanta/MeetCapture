#!/opt/homebrew/bin/python3
"""Prepare the one pinned WhisperKit QA artifact; never downloads during ASR.

    python3 qa/asr_whisper_model.py prepare --out /tmp/mc-whisper-large-v3-pinned

The public command always admits the downloader through resource_guard.py with
16 GiB RAM, 12 GiB disk and a 3,600-second deadline. Exit 75 means deferred.
Only public model/tokenizer/license files are fetched. No audio is read or sent.
The output must not exist; a failed download leaves evidence but no completed
manifest. Use a new output directory after a failure. Python standard library
only; no Hugging Face CLI, mutable revisions, alternate models or auth tokens.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.request

SDK_VERSION = "1.1.1"
SDK_REVISION = "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4"
MODEL_REPOSITORY = "argmaxinc/whisperkit-coreml"
MODEL_REVISION = "0f63a7800b00dd0226abd051b906c246e1907482"
MODEL_FOLDER = "openai_whisper-large-v3_947MB"
TOKENIZER_REPOSITORY = "openai/whisper-large-v3"
TOKENIZER_REVISION = "06f233fe06e710322aca913c1bc4249a0d71fce1"
CONTENT_SHA256 = "d13c4c7e93c175b29a439aa4e0d54811facb80d9ea3d0044ed9f0d74d4d1d9ef"
MANIFEST_NAME = "whisperkit-artifact.json"
FIXED_PROMPT = "Reunión de trabajo. Terminología: API, PostgreSQL, TypeScript, GitHub, Vercel."
FIXED_PROMPT_SHA256 = "d5ead012416bc45c1a09739cdf22a8f8c55012bf7351a50fa512d4c6752ece53"
# Tokenizer 0.22.2, from the pinned tokenizer.json, no special tokens. The Swift
# adapter MUST independently encode with the SDK's actual tokenizer and compare
# all tokens before using this identity; this list is not an alias or transcript.
FIXED_PROMPT_TOKENS = [8524, 409, 2560, 368, 18099, 13, 19835, 259, 29987, 25,
                       9362, 11, 10223, 33248, 39934, 11, 15576, 14237, 11,
                       23331, 11, 691, 2869, 338, 13]

# Hashes are frozen from the immutable repository revisions above. Large-file
# SHA-256 values are the repository's LFS object IDs. The other SHA-256 values
# were computed from source bytes after checking their immutable Git blob IDs.
# The adapter binds this entire path/size/hash inventory to CONTENT_SHA256.
MODEL_ASSETS = [
    ("AudioEncoder.mlmodelc/analytics/coremldata.bin", 243, "387cff66366595358aa7b02ca8a5c587000dcef963c3a38c24a77a765757881d"),
    ("AudioEncoder.mlmodelc/coremldata.bin", 348, "63b4db8a854c7a64a10b0a0b97048d6d8ee557536367f44dc9fb95fad4bffcf6"),
    ("AudioEncoder.mlmodelc/metadata.json", 1933, "b0deaf50cf43bbd8610b93ef694a1380ada2ee17680e6f881a7a03c26fb3c565"),
    ("AudioEncoder.mlmodelc/model.mil", 1138803, "4b06d167d112929866a7d8054772f4fd0b7804f40f4233aeff851eefbe57d0f5"),
    ("AudioEncoder.mlmodelc/weights/weight.bin", 353908416, "9b819fb62291e63c6b5596238a73964bfbdaccb8a12fd5672e7eb32639a57f83"),
    ("MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243, "7f478e6afa8fdee3711d97b00728f82ee4dcdf2912f7ff033ee0dfcf57bf28bb"),
    ("MelSpectrogram.mlmodelc/coremldata.bin", 329, "a888718e98af679eee42db9e3609627472c32f77e4fdda28f3735960cbf526b3"),
    ("MelSpectrogram.mlmodelc/metadata.json", 1878, "dcb839ca16e598dfb1720af0294a8e21ab18b3e5afab136093aa2fd5f5cfc923"),
    ("MelSpectrogram.mlmodelc/model.mil", 10166, "6e0c6fc2cb23de4e5b6c25897047c12402da201b5a8717fa5ee9f3108b1cb702"),
    ("MelSpectrogram.mlmodelc/weights/weight.bin", 373376, "81275398516781f9755514a5ab85db4687374dd611013625f3d4493588783968"),
    ("TextDecoder.mlmodelc/analytics/coremldata.bin", 243, "1a999e3332b206c426f9252001a3593702d3542aa4a00242f99e9baaeda4a063"),
    ("TextDecoder.mlmodelc/coremldata.bin", 637, "9b3e5707277d8c7297ea5e6075801c6d56a054e7ed1ab5dfec5692292c62e145"),
    ("TextDecoder.mlmodelc/metadata.json", 4959, "6ee6819dc8ad4990c626c52c711cc65c5c19536577bc5b590a7d1afaecda68c5"),
    ("TextDecoder.mlmodelc/model.mil", 1943315, "939d1919af974fee08186a36131c617ff004d63ccf9ebbb4a6314274e88960ec"),
    ("TextDecoder.mlmodelc/weights/weight.bin", 590719924, "e53c8476c43310ad9fd2f4be996b7d803208428b0b137848972932406a30ef2f"),
    ("config.json", 1163, "798b69c08cf93b2b03d94bea6eb3eb25fd4712259712d8a62ed2483fdf818a9e"),
    ("generation_config.json", 2810, "d24f9cca0f448609a71ae044b736023706382f45e9700e0dffb2559d10cf1fea"),
]
TOKENIZER_ASSETS = [
    ("config.json", 1272, "ad0e8d1e46f4d01f7861a21509e5d0f977d6cc1f367a370603c92541d819807b"),
    ("tokenizer.json", 2480617, "6d8cbd7cd0d8d5815e478dac67b85a26bbe77c1f5e0c6d76d1ce2abc0e5f21ca"),
    ("tokenizer_config.json", 282843, "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
]


def asset_inventory() -> list[dict]:
    assets = []
    for name, size, digest in MODEL_ASSETS:
        relative = f"{MODEL_FOLDER}/{name}"
        assets.append({"path": relative, "size": size, "sha256": digest,
                       "sourceURL": f"https://huggingface.co/{MODEL_REPOSITORY}/resolve/{MODEL_REVISION}/{relative}"})
    for name, size, digest in TOKENIZER_ASSETS:
        assets.append({"path": f"tokenizer/{name}", "size": size, "sha256": digest,
                       "sourceURL": f"https://huggingface.co/{TOKENIZER_REPOSITORY}/resolve/{TOKENIZER_REVISION}/{name}"})
    assets.extend([
        {"path": "notices/CoreML-README.md", "size": 571,
         "sha256": "e4ca9ea0f5569c3351fae48370fce30488492f6669d234fe8e34461a8c068c2e",
         "sourceURL": f"https://huggingface.co/{MODEL_REPOSITORY}/resolve/{MODEL_REVISION}/README.md"},
        {"path": "notices/Tokenizer-README.md", "size": 21829,
         "sha256": "b05416eb578e9fc65ce137f3401bafdf3bc2feac7448e7dd180dcd367b8cfb52",
         "sourceURL": f"https://huggingface.co/{TOKENIZER_REPOSITORY}/resolve/{TOKENIZER_REVISION}/README.md"},
        {"path": "notices/WhisperKit-LICENSE", "size": 1069,
         "sha256": "b8673adf319f1d6905c5c38cf69513f8857930fb3445566fa9839c6948bb85c4",
         "sourceURL": f"https://raw.githubusercontent.com/argmaxinc/argmax-oss-swift/{SDK_REVISION}/LICENSE"},
        {"path": "notices/WhisperKit-NOTICES", "size": 11646,
         "sha256": "8af554e910833382a04c73b2d9eaef669e031335c867de14b5cf631bd2239913",
         "sourceURL": f"https://raw.githubusercontent.com/argmaxinc/argmax-oss-swift/{SDK_REVISION}/NOTICES"},
    ])
    return sorted(assets, key=lambda entry: entry["path"])


def inventory_sha256(assets: list[dict]) -> str:
    canonical = "".join(f"{a['path']}:{a['size']}:{a['sha256']}\n"
                        for a in sorted(assets, key=lambda entry: entry["path"]))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def download_asset(root: Path, asset: dict) -> None:
    destination = root / asset["path"]
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + ".part")
    request = urllib.request.Request(asset["sourceURL"], headers={
        "User-Agent": "MeetCapture-QA-pinned-model-preparer/1",
        "Accept-Encoding": "identity",
    })
    digest = hashlib.sha256()
    size = 0
    print(f"Fetching {asset['path']}", file=sys.stderr, flush=True)
    with urllib.request.urlopen(request, timeout=120) as source, partial.open("xb") as target:
        if source.status != 200 or not source.url.startswith("https://"):
            raise ValueError(f"unexpected model download response: {asset['path']}")
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            size += len(chunk)
            if size > asset["size"]:
                raise ValueError(f"download exceeds pinned size: {asset['path']}")
            digest.update(chunk)
            target.write(chunk)
    if size != asset["size"] or digest.hexdigest() != asset["sha256"]:
        raise ValueError(f"pinned size/SHA-256 mismatch: {asset['path']}")
    partial.chmod(0o444)
    partial.rename(destination)


def prepare_artifact(output: Path) -> None:
    """Worker invoked only as a resource_guard child by the public command."""
    assets = asset_inventory()
    if inventory_sha256(assets) != CONTENT_SHA256:
        raise ValueError("frozen artifact inventory does not match the adapter's content identity")
    output = output.absolute()
    resolved = output.resolve()
    protected = [Path("/Applications"), Path("/System"), Path.home() / "Applications",
                 Path.home() / "meetings", Path.home() / ".meetcapture"]
    if any(resolved.is_relative_to(path.resolve()) for path in protected):
        raise ValueError(f"refusing installed-app or production data output: {output}")
    if output.exists() or output.is_symlink():
        raise ValueError(f"artifact output must not already exist: {output}")
    output.mkdir(mode=0o700, parents=True)
    output = output.resolve()
    for asset in assets:
        download_asset(output, asset)
    config = json.loads((output / MODEL_FOLDER / "config.json").read_text(encoding="utf-8"))
    generation = json.loads((output / MODEL_FOLDER / "generation_config.json").read_text(encoding="utf-8"))
    if (config.get("decoder_layers") != 32 or config.get("encoder_layers") != 32
            or config.get("vocab_size") != 51866 or config.get("num_mel_bins") != 128
            or not generation.get("alignment_heads")):
        raise ValueError("pinned artifact is not the declared aligned 32-layer large-v3 model")
    manifest = {
        "schemaVersion": 1, "engine": "whisperkit", "sdkVersion": SDK_VERSION,
        "sdkRevision": SDK_REVISION, "modelRepository": MODEL_REPOSITORY,
        "modelRevision": MODEL_REVISION, "modelFolder": MODEL_FOLDER,
        "decoderLayers": 32, "encoderLayers": 32,
        "precisionStatus": "compressed CoreML artifact; weight precision not verified",
        "tokenizerRepository": TOKENIZER_REPOSITORY,
        "tokenizerRevision": TOKENIZER_REVISION, "tokenizerFolder": "tokenizer",
        "contentSHA256": CONTENT_SHA256, "totalBytes": sum(a["size"] for a in assets),
        "files": assets,
        "fixedPrompt": {"text": FIXED_PROMPT, "sha256": FIXED_PROMPT_SHA256,
                        "tokens": FIXED_PROMPT_TOKENS, "addSpecialTokens": False,
                        "tokenDerivation": "tokenizers 0.22.2; Swift SDK tokenizer must match at load"},
        "licenses": {"sdk": "MIT", "coreMLRepositoryCard": "MIT",
                     "tokenizerRepositoryCard": "Apache-2.0",
                     "vendoredSwiftTransformers": "Apache-2.0; see notices/WhisperKit-NOTICES"},
    }
    path = output / MANIFEST_NAME
    with path.open("x", encoding="utf-8") as stream:
        json.dump(manifest, stream, sort_keys=True, ensure_ascii=False, indent=2, allow_nan=False)
        stream.write("\n")
    path.chmod(0o444)
    print(json.dumps({"artifactDirectory": str(output), "manifest": str(path),
                      "contentSHA256": CONTENT_SHA256, "totalBytes": manifest["totalBytes"],
                      "recognitionNetworkRequired": False}, sort_keys=True))


def find_guard(explicit: Path | None) -> Path:
    if explicit is not None:
        if not explicit.is_file():
            raise ValueError(f"resource guard not found: {explicit}")
        return explicit.resolve()
    for root in Path(__file__).resolve().parents:
        guard = root / "bin" / "system" / "resource_guard.py"
        if guard.is_file():
            return guard
    raise ValueError("resource_guard.py not found; supply --resource-guard (never bypass it)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("prepare", help="guarded, pinned download into a NEW directory")
    prepare.add_argument("--out", type=Path, required=True)
    prepare.add_argument("--resource-guard", type=Path)
    args = parser.parse_args()
    guard = find_guard(args.resource_guard)
    # No public unguarded worker CLI. The downloader is imported only inside the
    # admitted child, so a resource denial cannot start even the first request.
    worker = ("import runpy,sys; m=runpy.run_path(sys.argv[1]); "
              "m['prepare_artifact'](m['Path'](sys.argv[2]))")
    return subprocess.run([
        sys.executable, str(guard), "run", "--class", "cpu-heavy",
        "--ram-gib", "16", "--disk-gib", "12", "--run-seconds", "3600", "--",
        sys.executable, "-c", worker, str(Path(__file__).resolve()), str(args.out.absolute()),
    ], check=False).returncode


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"WhisperKit artifact preparation failed: {error}", file=sys.stderr)
        raise SystemExit(1)
