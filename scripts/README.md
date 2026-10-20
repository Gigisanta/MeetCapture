# scripts/

Maintainer helpers. The app bundles no scripts and runs no Python; speech
models download at runtime (see [`docs/THIRD_PARTY.md`](../docs/THIRD_PARTY.md)).
Checks that need a built app, fixtures, or a human display live in `qa/`.

| Script | Purpose |
| --- | --- |
| `version.sh` | Prints the version from `Resources/Info.plist`; `--check` rejects other version literals in tracked release files. |
| `deploy-site.sh` | Publishes `site/` to Vercel for maintainers who have separately authorized that external action. |

The canonical summary implementation is under `tools/summary/`, not an old
binary in this directory. The retired `com.maatwork.meetcapture.daemon`
launchd service is not a runtime dependency and must not be restored.

The legacy duration-based self-test is not a supported QA interface. Real
import and capture verification uses the `MEETCAPTURE_REAL_CHECK` contract documented in
[`qa/README.md`](../qa/README.md); its wrapper also owns the WER/reference
check and its temporary output directory. The wrapper compares all reported
records with the original `--reference` text, defaults `MEETCAPTURE_MAX_WER` to
`0.15` (`--max-wer` overrides it), and checks capture duration from the
captured PCM plus format sidecar. Its CLI remains `--app`, `--mode`, `--input`,
`--reference`, and `--output`, with the existing optional `--max-wer` and
`--required-words` arguments. For the capture diagnostic, the inherited
`MEETCAPTURE_CHECK_MIC_ONLY=1` opt-in selects microphone-only capture and the
report carries `micOnly:true`; the default remains `false`.
