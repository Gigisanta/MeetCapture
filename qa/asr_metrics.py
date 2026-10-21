"""Strict, local ASR scoring; operational acceptance gates are not evaluated here.

Only the predefined report.text hypothesis is scored. Technical repeat records
must not be passed as additional items. Explicit primary_evaluation selects the
primary population: a declared concatenated_evaluation block may be primary,
its component clips and diagnostic/offset variants must not also be primary.

Group bootstrap resamples complete group_id clusters, paired between arms.
A group is justified only by group_basis={kind, independence_verified: true,
evidence|description}; content hashes and invented speaker IDs do not establish
independence. Missing provenance produces descriptive, not inferential, CIs.

Optional annotation_review is an independent, complete reference-based audit:
{complete: true, evidence: "audit artifact", critical_errors: {
  names: {baseline: N, candidate: N}, amounts: {...}, dates: {...},
  negations: {...}}, phrase_losses: {baseline: N, candidate: N},
  spurious_repetitions: {...}, legitimate_repetitions_lost: {...}}.
Absent/incomplete annotations are not a successful critical-error check.
"""

from __future__ import annotations

import math
import random
import re
from collections import defaultdict
from importlib.metadata import version

import jiwer


_JIWER_VERSION = version("jiwer")
if _JIWER_VERSION != "4.0.0":
    raise RuntimeError("ASR QA requires JiWER 4.0.0; install qa/asr-requirements.lock")

_WORDS = jiwer.ReduceToListOfListOfWords()
_COUNTS = ("substitutions", "deletions", "insertions", "hits", "error_words")
_CRITICAL = ("names", "amounts", "dates", "negations")
_AUDITED = ("phrase_losses", "spurious_repetitions", "legitimate_repetitions_lost")


def tokens(text: str) -> list[str]:
    """Match capture-selftest.sh exactly; retain accents, numbers and negations."""
    return re.findall(r"[^\W_]+", text.casefold(), flags=re.UNICODE)


def _duration(value: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("duration_seconds must be a finite, positive number")
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise ValueError("duration_seconds must be a finite, positive number")
    return value


def score(reference: str, hypothesis: str, duration_seconds: float) -> dict:
    """Return JiWER alignment/counts using gate tokens, never normalized aliases.

    Indices are half-open Unicode-token indices, not character or time offsets.
    Empty references have WER=None and an explicit invented-words/minute rate.
    """
    if not isinstance(reference, str) or not isinstance(hypothesis, str):
        raise ValueError("reference and hypothesis must be strings")
    duration = _duration(duration_seconds)
    reference_tokens, hypothesis_tokens = tokens(reference), tokens(hypothesis)
    result = jiwer.process_words(
        " ".join(reference_tokens), " ".join(hypothesis_tokens),
        reference_transform=_WORDS, hypothesis_transform=_WORDS,
    )
    errors = result.substitutions + result.deletions + result.insertions
    alignments = [
        {
            "type": span.type,
            "reference_start": span.ref_start_idx,
            "reference_end": span.ref_end_idx,
            "hypothesis_start": span.hyp_start_idx,
            "hypothesis_end": span.hyp_end_idx,
            "reference_tokens": reference_tokens[span.ref_start_idx:span.ref_end_idx],
            "hypothesis_tokens": hypothesis_tokens[span.hyp_start_idx:span.hyp_end_idx],
        }
        for span in result.alignments[0]
    ]
    return {
        "substitutions": result.substitutions,
        "deletions": result.deletions,
        "insertions": result.insertions,
        "hits": result.hits,
        "reference_words": len(reference_tokens),
        "hypothesis_words": len(hypothesis_tokens),
        "error_words": errors,
        "wer": errors / len(reference_tokens) if reference_tokens else None,
        "duration_seconds": duration,
        "hallucinated_words_per_minute": (
            len(hypothesis_tokens) * 60 / duration if not reference_tokens else None
        ),
        "alignments": alignments,
    }


def _primary(item: dict) -> bool:
    explicit = item.get("primary_evaluation")
    if explicit is not None:
        if not isinstance(explicit, bool):
            raise ValueError(f"{item['id']}: primary_evaluation must be boolean")
        return explicit
    if "evaluation_role" in item:
        return item["evaluation_role"] == "primary"
    # Older schema-v1 original clips have no role. Never promote derived audio
    # implicitly; an amortized primary block needs an explicit declaration.
    coverage = set(item.get("coverage", []))
    return not (
        item.get("clip_map") or item.get("variant_of") or item.get("concatenation")
        or coverage.intersection({"diagnostic", "variant", "concatenation",
                                  "concatenated_evaluation", "offset_variant"})
    )


def _group(item: dict) -> str:
    group_id = item.get("group_id")
    if isinstance(group_id, str) and group_id.strip():
        return group_id
    # Unknown clips are one conservative cluster per source, not independent
    # recordings conjured from item names.
    return "unavailable:" + item["source"]


def _justified(item: dict) -> bool:
    basis = item.get("group_basis")
    if not isinstance(basis, dict) or basis.get("independence_verified") is not True:
        return False
    if item.get("group_independence_verified") is False:
        return False
    kind = basis.get("kind")
    return bool(
        isinstance(item.get("group_id"), str) and item["group_id"].strip()
        and isinstance(kind, str) and kind not in {
            "", "unavailable", "content_sha256", "content_component_block",
            "exact_audio_or_reference_content", "filename", "inferred_speaker",
        }
        and (basis.get("evidence") or basis.get("description"))
    )


def _quantile(sorted_values: list[float], probability: float) -> float:
    index = (len(sorted_values) - 1) * probability
    left = math.floor(index)
    right = math.ceil(index)
    return sorted_values[left] + (sorted_values[right] - sorted_values[left]) * (index - left)


def _bootstrap(rows: list[dict], seed: int, replicates: int) -> dict:
    grouped = defaultdict(lambda: [0, 0, 0])
    verified = defaultdict(list)
    for row in rows:
        group = _group(row["item"])
        values = grouped[group]
        values[0] += row["baseline"]["error_words"]
        values[1] += row["candidate"]["error_words"]
        values[2] += row["baseline"]["reference_words"]
        verified[group].append(_justified(row["item"]))
    groups = [grouped[key] for key in sorted(grouped)]
    justified_groups = sum(all(values) for values in verified.values())
    samples = []
    undefined = 0
    rng = random.Random(seed)
    if groups:
        for _ in range(replicates):
            baseline_errors = candidate_errors = words = 0
            for _ in range(len(groups)):
                baseline, candidate, reference = groups[rng.randrange(len(groups))]
                baseline_errors += baseline
                candidate_errors += candidate
                words += reference
            if words:
                samples.append((candidate_errors - baseline_errors) / words)
            else:
                undefined += 1
    samples.sort()
    return {
        "method": "paired percentile cluster bootstrap; candidate WER minus baseline WER",
        "seed": seed,
        "replicates": replicates,
        "groups": len(groups),
        "justified_independent_groups": justified_groups,
        "independence_verified": bool(groups) and justified_groups == len(groups),
        "descriptive_only": not groups or justified_groups != len(groups),
        "valid_replicates": len(samples),
        "zero_reference_replicates": undefined,
        "ci95_delta_wer": (
            [_quantile(samples, 0.025), _quantile(samples, 0.975)] if samples else None
        ),
    }


def _aggregate(rows: list[dict], seed: int, replicates: int, bootstrap: bool = True) -> dict:
    reference_words = sum(row["baseline"]["reference_words"] for row in rows)
    duration = math.fsum(row["baseline"]["duration_seconds"] for row in rows)
    silence = [row for row in rows if row["baseline"]["reference_words"] == 0]
    silence_seconds = math.fsum(row["baseline"]["duration_seconds"] for row in silence)
    arms = {}
    for arm in ("baseline", "candidate"):
        counts = {key: sum(row[arm][key] for row in rows) for key in _COUNTS}
        hallucinated = sum(row[arm]["hypothesis_words"] for row in silence)
        arms[arm] = {
            **counts,
            "wer": counts["error_words"] / reference_words if reference_words else None,
            "silence_hallucinated_words": hallucinated,
            "hallucinated_words_per_minute": (
                hallucinated * 60 / silence_seconds if silence_seconds else None
            ),
        }
    baseline_wer, candidate_wer = arms["baseline"]["wer"], arms["candidate"]["wer"]
    return {
        "comparison_status": (
            "not_comparable" if not rows else "comparable" if reference_words else "silence_only"
        ),
        "items": len(rows),
        "reference_words": reference_words,
        "duration_seconds": duration,
        "silence_items": len(silence),
        "silence_seconds": silence_seconds,
        **arms,
        "delta_wer": candidate_wer - baseline_wer if reference_words else None,
        "relative_wer_reduction": (
            (baseline_wer - candidate_wer) / baseline_wer if baseline_wer else None
        ),
        "paired_bootstrap": _bootstrap(rows, seed, replicates) if bootstrap else None,
    }


def _alignment_cells(result: dict) -> tuple[dict, dict]:
    words, insertions = {}, {}
    for span in result["alignments"]:
        start, end = span["reference_start"], span["reference_end"]
        if span["type"] == "insert":
            insertions[start] = span["hypothesis_tokens"]
        else:
            for offset, index in enumerate(range(start, end)):
                words[index] = (
                    [] if span["type"] == "delete" else [span["hypothesis_tokens"][offset]]
                )
    return words, insertions


def _error_pairs(row: dict) -> list[dict]:
    item = row["item"]
    reference = tokens(item["reference"])
    baseline_words, baseline_insertions = _alignment_cells(row["baseline"])
    candidate_words, candidate_insertions = _alignment_cells(row["candidate"])
    pairs = []
    units = [(i, i + 1, [word], baseline_words[i], candidate_words[i])
             for i, word in enumerate(reference)]
    units.extend((i, i, [], baseline_insertions.get(i, []), candidate_insertions.get(i, []))
                 for i in sorted(baseline_insertions.keys() | candidate_insertions.keys()))
    for start, end, expected, baseline, candidate in units:
        if baseline == candidate:
            continue
        kind = ("corrected" if candidate == expected else
                "introduced" if baseline == expected else "changed_error")
        pairs.append({
            "id": item["id"],
            "source": item["source"],
            "group_id": item.get("group_id"),
            "primary_evaluation": row["primary"],
            "kind": kind,
            "reference_start": start,
            "reference_end": end,
            "reference_tokens": expected,
            "baseline_tokens": baseline,
            "candidate_tokens": candidate,
        })
    return sorted(pairs, key=lambda pair: (pair["reference_start"], pair["reference_end"]))


def _review_counts(value: object) -> bool:
    return isinstance(value, dict) and all(
        isinstance(value.get(arm), int) and not isinstance(value[arm], bool) and value[arm] >= 0
        for arm in ("baseline", "candidate")
    )


def _annotations(rows: list[dict]) -> dict:
    missing = []
    counts = {key: {"baseline": 0, "candidate": 0} for key in (*_CRITICAL, *_AUDITED)}
    for row in rows:
        review = row["item"].get("annotation_review")
        critical = review.get("critical_errors") if isinstance(review, dict) else None
        if not (
            isinstance(review, dict) and review.get("complete") is True
            and isinstance(review.get("evidence"), str) and review["evidence"].strip()
            and isinstance(critical, dict)
            and all(_review_counts(critical.get(key)) for key in _CRITICAL)
            and all(_review_counts(review.get(key)) for key in _AUDITED)
        ):
            missing.append(row["item"]["id"])
            continue
        for key in counts:
            values = critical[key] if key in _CRITICAL else review[key]
            for arm in ("baseline", "candidate"):
                counts[key][arm] += values[arm]
    certified = bool(rows) and not missing
    return {
        "status": "certified" if certified else "not_certified",
        "missing_or_incomplete_item_ids": missing,
        "counts_on_reviewed_items": counts,
        "no_worsening": (
            all(values["candidate"] <= values["baseline"] for values in counts.values())
            if certified else None
        ),
    }


def compare(items: list[dict], seed: int = 20261020, replicates: int = 10000) -> dict:
    """Compare paired report.text outputs, excluding failures rather than scoring zero.

    Inputs follow results schema v1. Existing score fields are not trusted as a
    second hypothesis: this comparison derives both arm scores from the one
    stored reference/hypothesis pair. Per-condition tables overlap and must not
    be summed. The only inferential population is explicitly primary audio.
    """
    if not isinstance(items, list):
        raise ValueError("items must be a list of schema-v1 result items")
    if isinstance(seed, bool) or not isinstance(seed, int):
        raise ValueError("seed must be an integer")
    if isinstance(replicates, bool) or not isinstance(replicates, int) or replicates < 1:
        raise ValueError("replicates must be a positive integer")
    rows, excluded, ids, audio_ids = [], [], set(), {}
    primary_requested = 0
    sources = set()
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("each result item must be an object")
        for key in ("id", "source"):
            if not isinstance(item.get(key), str) or not item[key].strip():
                raise ValueError(f"each item needs a nonempty {key}")
        if item["id"] in ids:
            raise ValueError(f"duplicate result item id: {item['id']}")
        ids.add(item["id"])
        coverage = item.get("coverage", [])
        if not isinstance(coverage, list) or any(not isinstance(tag, str) for tag in coverage):
            raise ValueError(f"{item['id']}: coverage must be a list of strings")
        primary = _primary(item)
        primary_requested += int(primary)
        if primary:
            sources.add(item["source"])
        arms = item.get("arms")
        statuses = {arm: arms.get(arm, {}).get("pipeline_status")
                    if isinstance(arms, dict) and isinstance(arms.get(arm), dict) else None
                    for arm in ("baseline", "candidate")}
        reason = None
        if any(status != "passed" for status in statuses.values()):
            reason = "failed_or_incomplete_arm"
        elif not isinstance(item.get("reference"), str) or any(
            not isinstance(arms[arm].get("hypothesis"), str) for arm in statuses
        ):
            reason = "missing_reference_or_hypothesis"
        if reason:
            excluded.append({"id": item["id"], "source": item["source"],
                             "primary_evaluation": primary, "reason": reason,
                             "pipeline_status": statuses})
            continue
        # Technical replicas or a clip accidentally listed twice cannot inflate
        # either denominator. Conflicting references are an invalid experiment.
        audio_id = item.get("wav_sha256")
        if primary and isinstance(audio_id, str) and audio_id:
            if audio_id in audio_ids:
                previous = audio_ids[audio_id]
                if previous["reference"] != item["reference"]:
                    raise ValueError(f"conflicting references for primary audio {audio_id}")
                excluded.append({"id": item["id"], "source": item["source"],
                                 "primary_evaluation": True, "reason": "duplicate_primary_audio",
                                 "duplicate_of": previous["id"]})
                continue
            audio_ids[audio_id] = item
        duration = _duration(item.get("duration_seconds"))
        rows.append({"item": item, "primary": primary,
                     **{arm: score(item["reference"], arms[arm]["hypothesis"], duration)
                        for arm in statuses}})
    rows.sort(key=lambda row: row["item"]["id"])
    primary_rows = [row for row in rows if row["primary"]]
    diagnostic_rows = [row for row in rows if not row["primary"]]
    pooled = _aggregate(primary_rows, seed, replicates)
    per_source = {source: _aggregate([row for row in primary_rows
                                     if row["item"]["source"] == source], seed, replicates)
                  for source in sorted(sources)}
    conditions = defaultdict(list)
    for row in rows:
        for condition in sorted(set(row["item"].get("coverage", []))):
            conditions[condition].append(row)
    by_condition = {
        key: {"primary": _aggregate([row for row in values if row["primary"]],
                                     seed, replicates, bootstrap=False),
              "diagnostic": _aggregate([row for row in values if not row["primary"]],
                                        seed, replicates, bootstrap=False)}
        for key, values in sorted(conditions.items())
    }
    annotations = _annotations(primary_rows)
    silence_rows = [row for row in rows if row["baseline"]["reference_words"] == 0]
    silence = _aggregate(silence_rows, seed, replicates, bootstrap=False)
    silence_no_worsening = (
        all(row["candidate"]["hypothesis_words"] <= row["baseline"]["hypothesis_words"]
            for row in silence_rows) if silence_rows else None
    )
    bootstrap = pooled["paired_bootstrap"]
    ci = bootstrap["ci95_delta_wer"]
    source_no_worsening = bool(per_source) and all(
        values["delta_wer"] is not None and values["delta_wer"] <= 0
        for values in per_source.values()
    )
    blockers = []
    if not primary_rows:
        blockers.append("no_comparable_primary_audio")
    if any(entry["primary_evaluation"] for entry in excluded):
        blockers.append("incomplete_primary_coverage")
    if not primary_rows or {row["item"].get("split") for row in primary_rows} != {"holdout"}:
        blockers.append("not_an_exclusive_holdout_evaluation")
    if pooled["reference_words"] == 0:
        blockers.append("zero_reference_words")
    if pooled["baseline"]["error_words"] < 100:
        blockers.append("fewer_than_100_baseline_errors")
    if bootstrap["justified_independent_groups"] < 20:
        blockers.append("fewer_than_20_justified_independent_groups")
    if not bootstrap["independence_verified"]:
        blockers.append("group_independence_not_verified")
    if replicates < 10000:
        blockers.append("fewer_than_10000_bootstrap_replicates")
    if ci is None or ci[1] >= 0 or bootstrap["zero_reference_replicates"]:
        blockers.append("paired_ci_does_not_establish_lower_wer")
    relative = pooled["relative_wer_reduction"]
    if relative is None or relative < 0.20:
        blockers.append("relative_wer_reduction_below_20_percent_or_undefined")
    if not source_no_worsening:
        blockers.append("source_non_regression_not_established")
    if annotations["status"] != "certified":
        blockers.append("critical_phrase_repetition_annotations_not_certified")
    elif not annotations["no_worsening"]:
        blockers.append("critical_phrase_or_repetition_regression")
    if silence_no_worsening is None:
        blockers.append("silence_hallucinations_not_evaluated")
    elif not silence_no_worsening:
        blockers.append("silence_hallucination_regression")
    return {
        "schema_version": 1,
        "scorer": {"name": "JiWER", "version": _JIWER_VERSION,
                   "tokenization": "re.findall(r'[^\\W_]+', text.casefold(), flags=re.UNICODE)",
                   "alignment_indices": "half-open token indices; not timestamps",
                   "hypothesis": "one predefined report.text per audio and arm"},
        "primary_requested_items": primary_requested,
        "comparable_items": len(rows),
        "pooled": pooled,
        "per_source": per_source,
        "by_condition": by_condition,
        "diagnostic": _aggregate(diagnostic_rows, seed, replicates, bootstrap=False),
        "excluded": excluded,
        "annotations": annotations,
        "silence": {**silence, "no_worsening": silence_no_worsening},
        "error_pairs": [pair for row in rows for pair in _error_pairs(row)],
        "decision": {
            "strong_improvement_demonstrated": not blockers,
            "status": "strong_precision_improvement" if not blockers else "not_demonstrated",
            "blockers": blockers,
            "source_no_worsening": source_no_worsening,
            "acceptance_status": "not_evaluated",
            "production_readiness": "not_evaluated",
            "limits": [
                "Descriptive deltas are not a claim of independent speakers or meetings.",
                "Concatenated evaluation is not spontaneous conversation; conditions overlap.",
                "Operational capture, cancellation, recovery and adoption require separate evidence.",
                "Reference uncertainty requires an independent audit; no reference is repaired here.",
            ],
        },
    }
