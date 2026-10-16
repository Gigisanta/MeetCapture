# tools/summary/

This directory contains the canonical summary implementation:
`meetcapture_summary_dispatcher.py`. It is a stdlib-only Python consumer of
MeetCapture's version 2 `.pending` handoff. It validates the contract and
transcript checksum, writes `<meeting-id>.summary.json` and
`<meeting-id>.summary.html`, and then acknowledges the handoff as `.done`.

The nested `tools/summary/` source is canonical. An existing host-level legacy
parent binary is not updated by this installer and is not an alternative
source. The optional per-user launchd agent only schedules this dispatcher;
the retired `com.maatwork.meetcapture.daemon` service and other legacy
`com.*` services must not be re-enabled.

## How it runs

`install-summary-agent.sh` installs the dispatcher as the optional
`ai.hermes.meetcapture-summary` launchd agent. Before installing, it rejects
the legacy plist or a loaded `com.maatwork.meetcapture-summary` service and
exits without unloading or killing it. Migrating that live legacy service is a
separate operational action. The new agent wakes on changes to `~/meetings`
and every 15 minutes so retry backoff can expire. Each launchd invocation runs
one pass and exits; it does not start the MeetCapture app or a capture service.

```bash
tools/summary/install-summary-agent.sh
python3 tools/summary/meetcapture_summary_dispatcher.py --once
python3 tools/summary/meetcapture_summary_dispatcher.py --retry-failed
```

`--watch` is available for a manually managed polling process. The normal
launchd template uses `--once`. Uninstalling the optional scheduler does not
remove the dispatcher or existing handoffs.

## Configuration

`~/.meetcapture/summary.json` is edited by Settings › Resumen and is created
with private permissions when needed:

| Key | Default | Meaning |
| --- | --- | --- |
| `endpoint` | `http://127.0.0.1:8080/v1` | OpenAI-compatible chat endpoint. The local MLX route is the gateway at `:8080/v1`; gateway-managed backends are internal, so clients must not address `:180xx` directly. |
| `api_key` | `mlx-local` | Bearer value sent to the configured endpoint. Keep real credentials outside the repository. |
| `model` | `maat/smart` | Model id; `null` allows discovery through the configured gateway. |
| `max_tokens` | `2000` | Completion budget. |
| `keep_audio` | `false` | Keep handoff audio after a successful summary. |
| `dry_run` | `false` | Write a deterministic mock summary without calling the endpoint. |

The dispatcher also accepts `MEETCAPTURE_MEETINGS_DIR` (default
`~/meetings`) and `MEETCAPTURE_SUMMARY_CONFIG` for isolated tests or a
deliberately selected configuration file. `MEETCAPTURE_POST_SUMMARY` is an
optional user-supplied executable hook; it is not part of the core handoff
contract.

The dispatcher confines transcript and audio paths from a contract to the
selected meetings directory. It writes private logs and artifacts and never
acknowledges a contract whose version, identity, paths, transcript, or
checksum is invalid.

## States on disk

| File | Meaning |
| --- | --- |
| `meet-X.pending` | Durable handoff written by the app; eligible for the next pass. |
| `meet-X.pending.retry`, `.retry.N` | Transient failure such as an endpoint error. Backoff starts at 5 minutes, doubles up to 6 hours, and is evaluated from the latest failure. |
| `meet-X.pending.failed` | Eight transient attempts were exhausted. `--retry-failed` moves it back to `.pending` without overwriting a colliding handoff. |
| `meet-X.pending.error` | Permanent input failure: invalid JSON or version, path escape, missing transcript, checksum mismatch, or invalid transcript. The handoff is retained for diagnosis. |
| `meet-X.done` | The summary JSON and HTML were published and the handoff was acknowledged. Audio is then removed unless `keep_audio` is true. A later `meet-X.pending` with the same checksum is a duplicate and is skipped; one with a different checksum is a revision (the app filled the gaps of a transcript) and replaces the summary and the `.done`. A handoff with gaps carries `audioPath: null` because the app keeps the audio for that retry. |

All three summary artifacts (JSON, HTML and Markdown) are prepared through temporary files and rollback. If
publishing or acknowledgement fails, the dispatcher keeps the handoff and
does not leave a partial successful summary.

The Markdown note is saved beside the other summary artifacts as
`<meetingId>.summary.md` (private mode `0600`). It contains YAML frontmatter,
the structured summary, decisions, unchecked tasks, attendees and the full
transcript. Notes typed during recording live in `<meetingId>.notes.md` and
are included in the summary prompt and published artifacts. Open the summary
from the history row or copy it into a Markdown/Obsidian
vault. Optional `tag_vocabulary_dir` in `~/.meetcapture/summary.json` points
to an existing Markdown directory. Only tag names are collected from up to
300 regular files of at most 64 KiB each; symlinks are skipped. The prompt
receives those tag names and output tags are checked against the same list.

## Verification

`test_dispatcher.py` exercises the lifecycle, checksum and path failures,
retry/backoff, dry-run output, collision handling, and artifact rollback in a
temporary directory. `test_real_summary_check.py` exercises the offline
content and safety gate, including rejection of dry-run output, invented
assignees, missing dates, unsafe fixture roots, and direct backend URLs. Both
are fixture tests: neither proves the macOS app's capture or import path, nor
does either prove that the configured endpoint is reachable.

The opt-in `real_summary_check.py` is the integration check for a live local
gateway. It uses a temporary v2 handoff with `dry_run=false`, verifies the
JSON and HTML content, reruns the dispatcher for idempotency, and returns `0`
only for a real response satisfying the assertions. It returns `1` for an
assertion failure and `2` when the gateway or its bounded GPU-hold prerequisite
is unavailable. `--keep-audio` and `--delete-audio` verify the corresponding
retention behavior; the temporary fixture is removed at exit. This command is
separate from the offline tests and is not a general system-health result.

```bash
python3 tools/summary/test_dispatcher.py
python3 tools/summary/test_real_summary_check.py
```
