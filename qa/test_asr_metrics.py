"""Behavioral contracts for strict scoring, paired comparison and holdout freeze.

Run after installing the locked QA environment:
    python -m unittest discover -s qa -p 'test_asr_metrics.py' -v
"""

import copy
import importlib.util
import math
from pathlib import Path
import unittest

from asr_metrics import compare, score, tokens

_runner_spec = importlib.util.spec_from_file_location("asr_ab", Path(__file__).with_name("asr-ab.py"))
asr_ab = importlib.util.module_from_spec(_runner_spec)
_runner_spec.loader.exec_module(asr_ab)


def item(identifier, reference="pago hoy", baseline="pago ayer", candidate="pago hoy",
         source="argentina", group=None, **extra):
    return {
        "id": identifier,
        "source": source,
        "split": "holdout",
        "group_id": group if group is not None else identifier,
        "group_basis": {"kind": "original_recording_id", "independence_verified": True,
                        "evidence": "Independent original recordings in this synthetic fixture"},
        "duration_seconds": 60.0,
        "reference": reference,
        "coverage": [],
        "primary_evaluation": True,
        "arms": {
            "baseline": {"pipeline_status": "passed", "hypothesis": baseline},
            "candidate": {"pipeline_status": "passed", "hypothesis": candidate},
        },
        **extra,
    }


def audited():
    return {
        "complete": True,
        "evidence": "Synthetic reference audit fixture, not an experiment result",
        "critical_errors": {
            category: {"baseline": 0, "candidate": 0}
            for category in ("names", "amounts", "dates", "negations")
        },
        **{category: {"baseline": 0, "candidate": 0}
           for category in ("phrase_losses", "spurious_repetitions",
                            "legitimate_repetitions_lost")},
    }


def precision_population():
    # Exactly 100 baseline errors in 20 independently identified fixture groups.
    rows = [item(str(index), reference="uno dos tres cuatro cinco", baseline="a b c d e",
                 candidate="uno dos tres cuatro cinco", annotation_review=audited())
            for index in range(20)]
    rows.append(item("silence", reference="", baseline="inventado", candidate="",
                     primary_evaluation=False, evaluation_role="diagnostic", coverage=["silence"]))
    return rows


class StrictScoreTests(unittest.TestCase):
    def test_gate_unicode_token_contract(self):
        self.assertEqual(
            tokens(" ¡SÍ! NO_no; API, 1.234,56 Straße—mañana. "),
            ["sí", "no", "no", "api", "1", "234", "56", "strasse", "mañana"],
        )

    def test_hand_counted_scores(self):
        # One owning table protects acoustic content: no accent stripping,
        # numeric normalization, negation removal or repetition deduplication.
        cases = [
            ("exact", "Reunión mañana", "REUNIÓN, mañana!", (0, 0, 0, 2), 2, 0.0),
            ("substitution", "pago hoy", "pago mañana", (1, 0, 0, 1), 2, 0.5),
            ("deletion", "pago hoy", "pago", (0, 1, 0, 1), 2, 0.5),
            ("insertion", "pago hoy", "pago extra hoy", (0, 0, 1, 2), 2, 0.5),
            ("accent", "sí", "si", (1, 0, 0, 0), 1, 1.0),
            ("number", "pago 120", "pago 121", (1, 0, 0, 1), 2, 0.5),
            ("negation", "no autorizo pago", "autorizo pago", (0, 1, 0, 2), 3, 1 / 3),
            ("legitimate repeat", "no no autorizo", "no autorizo", (0, 1, 0, 2), 3, 1 / 3),
            ("preserved repeat", "no no", "NO, no.", (0, 0, 0, 2), 2, 0.0),
            ("above 100 percent", "sí", "no no no", (1, 0, 2, 0), 1, 3.0),
            ("correct silence", "", "", (0, 0, 0, 0), 0, None),
            ("hallucinated silence", "", "muchas gracias", (0, 0, 2, 0), 0, None),
        ]
        for name, reference, hypothesis, expected, words, wer in cases:
            with self.subTest(name=name):
                result = score(reference, hypothesis, 30.0)
                self.assertEqual(tuple(result[key] for key in
                                       ("substitutions", "deletions", "insertions", "hits")), expected)
                self.assertEqual(result["reference_words"], words)
                self.assertEqual(result["error_words"], sum(expected[:3]))
                self.assertEqual(result["wer"], wer)
                self.assertEqual(result["hallucinated_words_per_minute"],
                                 expected[2] * 2 if words == 0 else None)

    def test_alignment_preserves_error_text_and_half_open_positions(self):
        result = score("pago hoy", "pago mañana", 5)
        self.assertEqual(result["alignments"], [
            {"type": "equal", "reference_start": 0, "reference_end": 1,
             "hypothesis_start": 0, "hypothesis_end": 1,
             "reference_tokens": ["pago"], "hypothesis_tokens": ["pago"]},
            {"type": "substitute", "reference_start": 1, "reference_end": 2,
             "hypothesis_start": 1, "hypothesis_end": 2,
             "reference_tokens": ["hoy"], "hypothesis_tokens": ["mañana"]},
        ])
        insertion = score("", "muchas gracias", 60)["alignments"]
        self.assertEqual(insertion, [
            {"type": "insert", "reference_start": 0, "reference_end": 0,
             "hypothesis_start": 0, "hypothesis_end": 2,
             "reference_tokens": [], "hypothesis_tokens": ["muchas", "gracias"]},
        ])

    def test_invalid_duration_cannot_fabricate_silence_rate(self):
        for duration in (0, -1, math.nan, math.inf, -math.inf, True, "60", None):
            with self.subTest(duration=duration), self.assertRaises(ValueError):
                score("", "inventado", duration)


class FrozenCandidateTests(unittest.TestCase):
    binary_digest = "a" * 64
    manifest_digest = "b" * 64
    timeout_seconds = 7200

    def frozen_provenance(self):
        provenance = {
            "schema_version": 1, "binary_sha256": self.binary_digest, "commit": "c" * 40,
            "engine": "parakeet",
            "model": {"name": "parakeet-tdt-0.6b-v3", "revision": "weights-r1",
                      "artifacts": {"encoder": {"sha256": "d" * 64}}},
            "dependencies": {"FluidAudio": {"revision": "sdk-r1"}},
            "configuration": {
                "decoder": {"seamGapRepairMinGapSeconds": 1.5, "prompt": None},
                "chunking": {"target_seconds": 300}, "gate": {"enabled": True}, "aliases": {},
                "merge": {"microphone_lexical_dedupe": True},
                "future_component": {"unknown_knob": 7},
            },
            "environment": {"MEETCAPTURE_EXPERIMENT_VARIANT": "baseline",
                            "MEETCAPTURE_EXPERIMENT_MODEL_PATH": "/local/models/r1"},
            "model_artifacts": [{"path": "/local/models/r1", "sha256": "e" * 64}],
            "observations": {"measured_at": "2026-10-01T00:00:00Z", "cache_state": "cold"},
        }
        identity = asr_ab.effective_identity(provenance, self.timeout_seconds)
        provenance["frozen_candidate"] = {
            "binary_sha256": self.binary_digest, "manifest_sha256": self.manifest_digest,
            "effective_identity_sha256": identity["effective_identity_sha256"],
            "selected_on": "dev", "frozen_at": "2026-10-01T00:00:00Z",
        }
        return provenance

    def require_freeze(self, provenance, timeout_seconds=None):
        asr_ab._require_frozen_candidate(
            provenance, self.binary_digest, self.manifest_digest,
            self.timeout_seconds if timeout_seconds is None else timeout_seconds)

    def test_holdout_rejects_effective_changes_with_the_same_binary(self):
        frozen = self.frozen_provenance()
        self.require_freeze(frozen)
        cases = [
            ("chunk", ("configuration", "chunking", "target_seconds"), 600),
            ("gap", ("configuration", "decoder", "seamGapRepairMinGapSeconds"), 0.5),
            ("dedupe", ("configuration", "merge", "microphone_lexical_dedupe"), False),
            ("prompt", ("configuration", "decoder", "prompt"), "Reunión de trabajo."),
            ("future knob", ("configuration", "future_component", "unknown_knob"), 8),
            ("gate", ("configuration", "gate", "enabled"), False),
            ("aliases", ("configuration", "aliases"), {"uno": "dos"}),
            ("engine", ("engine",), "whisperkit"),
            ("model revision", ("model", "revision"), "weights-r2"),
            ("model artifact", ("model", "artifacts", "encoder", "sha256"), "f" * 64),
            ("dependency", ("dependencies", "FluidAudio", "revision"), "sdk-r2"),
            ("artifact inventory", ("model_artifacts",), [{"sha256": "f" * 64}]),
            ("environment", ("environment", "MEETCAPTURE_EXPERIMENT_VARIANT"), "candidate"),
            ("model path", ("environment", "MEETCAPTURE_EXPERIMENT_MODEL_PATH"), "/local/models/r2"),
        ]
        for name, path, replacement in cases:
            with self.subTest(change=name):
                changed = copy.deepcopy(frozen)
                target = changed
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = replacement
                with self.assertRaisesRegex(ValueError, "holdout remains unopened"):
                    self.require_freeze(changed)
        with self.subTest(change="effective timeout"):
            with self.assertRaisesRegex(ValueError, "holdout remains unopened"):
                self.require_freeze(frozen, timeout_seconds=3600)
        legacy = copy.deepcopy(frozen)
        del legacy["frozen_candidate"]["effective_identity_sha256"]
        with self.subTest(change="legacy binary-only freeze"):
            with self.assertRaisesRegex(ValueError, "holdout remains unopened"):
                self.require_freeze(legacy)

    def test_canonical_order_and_volatile_metadata_do_not_invalidate_a_matching_freeze(self):
        frozen = self.frozen_provenance()
        original = asr_ab.effective_identity(frozen, self.timeout_seconds)

        def reverse_keys(value):
            if isinstance(value, dict):
                return {key: reverse_keys(child) for key, child in reversed(value.items())}
            if isinstance(value, list):
                return [reverse_keys(child) for child in value]
            return value

        reordered = reverse_keys(frozen)
        reordered["frozen_candidate"].update(frozen_at="2026-10-02T00:00:00Z", decision_note="dev selection")
        reordered["observations"].update(measured_at="2026-10-02T00:00:00Z", cache_state="warm")
        self.assertEqual(asr_ab.effective_identity(reordered, self.timeout_seconds), original)
        self.require_freeze(reordered)
        # Dev can obtain the identity before a freeze exists, without a circular hash.
        del reordered["frozen_candidate"]
        self.assertEqual(asr_ab.effective_identity(reordered, self.timeout_seconds), original)


class PairedComparisonTests(unittest.TestCase):
    def test_micro_denominator_and_predefined_hypothesis_not_technical_replicas(self):
        first = item("first")
        first["arms"]["baseline"]["technical_replicas"] = [
            {"hypothesis": "pago hoy"}, {"hypothesis": "pago hoy"}]
        second = item("second", reference="no autorizo este pago ahora por favor",
                      baseline="no autorizo este pago ahora por favor",
                      candidate="autorizo este pago ahora por favor")
        result = compare([first, second], replicates=100)
        self.assertEqual(result["pooled"]["reference_words"], 9)
        self.assertEqual(result["pooled"]["baseline"]["error_words"], 1)
        self.assertEqual(result["pooled"]["candidate"]["error_words"], 1)
        self.assertEqual(result["pooled"]["baseline"]["wer"], 1 / 9)
        self.assertEqual(result["pooled"]["candidate"]["wer"], 1 / 9)
        self.assertEqual(
            [(pair["id"], pair["kind"], pair["reference_tokens"],
              pair["baseline_tokens"], pair["candidate_tokens"])
             for pair in result["error_pairs"]],
            [("first", "corrected", ["hoy"], ["ayer"], ["hoy"]),
             ("second", "introduced", ["no"], ["no"], [])],
        )

    def test_failed_arm_is_incomplete_not_a_zero_error_transcript(self):
        failed = item("failed")
        failed["arms"]["candidate"].update(pipeline_status="timeout", hypothesis="", score=None)
        result = compare([item("ok"), failed], replicates=100)
        self.assertEqual(result["pooled"]["items"], 1)
        self.assertEqual(result["pooled"]["reference_words"], 2)
        self.assertEqual(result["pooled"]["baseline"]["wer"], 0.5)
        self.assertEqual(result["excluded"][0]["reason"], "failed_or_incomplete_arm")
        self.assertIn("incomplete_primary_coverage", result["decision"]["blockers"])
        all_failed = compare([failed], replicates=10)
        self.assertEqual(all_failed["pooled"]["comparison_status"], "not_comparable")
        self.assertIsNone(all_failed["pooled"]["baseline"]["wer"])
        self.assertIsNone(all_failed["pooled"]["candidate"]["wer"])

    def test_cluster_bootstrap_keeps_paired_original_groups_together(self):
        first = item("first", reference="a b", baseline="x b", candidate="a b", group="original")
        second = item("second", reference="a b c d e f g h", baseline="a b c d e f g h",
                      candidate="x y z w e f g h", group="original")
        clustered = compare([first, second], seed=20261020, replicates=400)
        interval = clustered["pooled"]["paired_bootstrap"]
        self.assertEqual(interval["groups"], 1)
        self.assertEqual(interval["justified_independent_groups"], 1)
        self.assertEqual(interval["ci95_delta_wer"], [0.3, 0.3])
        separate = copy.deepcopy(second)
        separate["group_id"] = "another_original"
        unclustered = compare([first, separate], seed=20261020, replicates=400)
        self.assertEqual(unclustered["pooled"]["paired_bootstrap"]["groups"], 2)
        self.assertEqual(unclustered["pooled"]["paired_bootstrap"]["ci95_delta_wer"], [-0.5, 0.5])
        # Ordering result JSON must not change seeded cluster resampling.
        reordered = compare([separate, first], seed=20261020, replicates=400)
        self.assertEqual(unclustered, reordered)

    def test_explicit_primary_blocks_do_not_add_diagnostic_variants_to_denominator(self):
        block = item("block", primary_evaluation=True, evaluation_role="primary",
                     coverage=["concatenated_evaluation"], clip_map=[{"id": "clip"}], group="original")
        diagnostic = item("offset", baseline="wrong wrong", candidate="wrong wrong",
                          primary_evaluation=False, evaluation_role="diagnostic",
                          coverage=["offset_variant"], group="original")
        implicit_derived = item("derived", coverage=["concatenation"], group="original")
        del implicit_derived["primary_evaluation"]
        result = compare([block, diagnostic, implicit_derived], replicates=50)
        self.assertEqual(result["pooled"]["items"], 1)
        self.assertEqual(result["pooled"]["reference_words"], 2)
        self.assertEqual(result["pooled"]["paired_bootstrap"]["groups"], 1)
        self.assertEqual(result["diagnostic"]["items"], 2)
        self.assertEqual(result["by_condition"]["concatenated_evaluation"]["primary"]["items"], 1)
        self.assertEqual(result["by_condition"]["offset_variant"]["primary"]["items"], 0)

    def test_repeated_primary_audio_cannot_inflate_words_or_groups(self):
        first = item("first", wav_sha256="same-audio-content")
        duplicate = item("technical-repeat", wav_sha256="same-audio-content")
        result = compare([first, duplicate], replicates=50)
        self.assertEqual(result["pooled"]["reference_words"], 2)
        self.assertEqual(result["pooled"]["paired_bootstrap"]["groups"], 1)
        self.assertEqual(result["excluded"][0]["reason"], "duplicate_primary_audio")
        self.assertIn("incomplete_primary_coverage", result["decision"]["blockers"])
        duplicate["reference"] = "different reference"
        with self.assertRaisesRegex(ValueError, "conflicting references"):
            compare([first, duplicate], replicates=50)
        with self.assertRaisesRegex(ValueError, "duplicate result item id"):
            compare([first, first], replicates=50)

    def test_silence_has_weighted_invented_word_rate_without_wer_division(self):
        rows = [item("short", reference="", baseline="a b", candidate="", duration_seconds=30),
                item("long", reference="", baseline="c d", candidate="e", duration_seconds=90)]
        result = compare(rows, replicates=50)
        pooled = result["pooled"]
        self.assertEqual(pooled["comparison_status"], "silence_only")
        self.assertIsNone(pooled["baseline"]["wer"])
        self.assertIsNone(pooled["relative_wer_reduction"])
        self.assertEqual(pooled["baseline"]["hallucinated_words_per_minute"], 2)
        self.assertEqual(pooled["candidate"]["hallucinated_words_per_minute"], 0.5)
        self.assertIsNone(pooled["paired_bootstrap"]["ci95_delta_wer"])
        self.assertEqual(pooled["paired_bootstrap"]["zero_reference_replicates"], 50)
        self.assertFalse(result["decision"]["strong_improvement_demonstrated"])

    def test_unavailable_provenance_and_annotations_never_become_certification(self):
        rows = precision_population()
        for row in rows:
            row["group_basis"] = {"kind": "content_component_block", "independence_verified": False,
                                  "description": "Content grouping, no speaker/session provenance"}
            row.pop("annotation_review", None)
        result = compare(rows, replicates=100)
        self.assertEqual(result["pooled"]["baseline"]["error_words"], 100)
        self.assertEqual(result["pooled"]["relative_wer_reduction"], 1)
        self.assertEqual(result["pooled"]["paired_bootstrap"]["groups"], 20)
        self.assertEqual(result["pooled"]["paired_bootstrap"]["justified_independent_groups"], 0)
        self.assertTrue(result["pooled"]["paired_bootstrap"]["descriptive_only"])
        self.assertEqual(result["annotations"]["status"], "not_certified")
        self.assertIsNone(result["annotations"]["no_worsening"])
        self.assertFalse(result["decision"]["strong_improvement_demonstrated"])
        self.assertIn("group_independence_not_verified", result["decision"]["blockers"])
        self.assertIn("critical_phrase_repetition_annotations_not_certified", result["decision"]["blockers"])
        # A content-hash flag cannot manufacture recording/speaker provenance.
        for row in rows:
            row["group_basis"].update(kind="exact_audio_or_reference_content", independence_verified=True)
        flagged = compare(rows, replicates=10)
        self.assertEqual(flagged["pooled"]["paired_bootstrap"]["justified_independent_groups"], 0)
        unknown = [item("one", group_id=None), item("two", group_id=None)]
        self.assertEqual(compare(unknown, replicates=10)["pooled"]["paired_bootstrap"]["groups"], 1)

    def test_strong_claim_requires_all_predeclared_minima(self):
        rows = precision_population()
        complete = compare(rows)
        self.assertEqual(complete["pooled"]["baseline"]["error_words"], 100)
        self.assertEqual(complete["pooled"]["paired_bootstrap"]["justified_independent_groups"], 20)
        self.assertEqual(complete["pooled"]["paired_bootstrap"]["ci95_delta_wer"], [-1.0, -1.0])
        self.assertTrue(complete["decision"]["strong_improvement_demonstrated"])
        self.assertEqual(complete["decision"]["acceptance_status"], "not_evaluated")
        insufficient = compare(rows[1:])
        self.assertIn("fewer_than_100_baseline_errors", insufficient["decision"]["blockers"])
        self.assertIn("fewer_than_20_justified_independent_groups", insufficient["decision"]["blockers"])
        self.assertFalse(insufficient["decision"]["strong_improvement_demonstrated"])
        # A fully reviewed zero-error baseline still has no relative reduction.
        exact = compare([item("exact", baseline="pago hoy", annotation_review=audited())], replicates=10)
        self.assertIsNone(exact["pooled"]["relative_wer_reduction"])
        self.assertFalse(exact["decision"]["strong_improvement_demonstrated"])

    def test_pooled_gain_cannot_hide_source_or_critical_category_regression(self):
        rows = precision_population()
        rows.append(item("media", reference="pago", baseline="pago", candidate="paso",
                         source="media", annotation_review=audited()))
        result = compare(rows, replicates=100)
        self.assertLess(result["pooled"]["delta_wer"], 0)
        self.assertGreater(result["per_source"]["media"]["delta_wer"], 0)
        self.assertFalse(result["decision"]["source_no_worsening"])
        self.assertIn("source_non_regression_not_established", result["decision"]["blockers"])
        critical_rows = precision_population()
        critical_rows[0]["annotation_review"]["critical_errors"]["names"]["candidate"] = 1
        critical_rows[1]["annotation_review"]["critical_errors"]["amounts"]["baseline"] = 1
        critical = compare(critical_rows, replicates=100)
        self.assertEqual(critical["annotations"]["status"], "certified")
        self.assertFalse(critical["annotations"]["no_worsening"])
        self.assertIn("critical_phrase_or_repetition_regression", critical["decision"]["blockers"])

    def test_no_strong_claim_on_development_or_invented_silence_words(self):
        rows = precision_population()
        rows[0]["split"] = "dev"
        rows[-1]["arms"]["baseline"]["hypothesis"] = ""
        rows[-1]["arms"]["candidate"]["hypothesis"] = "inventado"
        result = compare(rows, replicates=100)
        self.assertIn("not_an_exclusive_holdout_evaluation", result["decision"]["blockers"])
        self.assertIn("silence_hallucination_regression", result["decision"]["blockers"])
        self.assertFalse(result["silence"]["no_worsening"])


if __name__ == "__main__":
    unittest.main()
