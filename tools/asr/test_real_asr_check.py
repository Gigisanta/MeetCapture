#!/usr/bin/env python3
"""Tests for the real sherpa acceptance runner.

The helper tests use disposable files and the actual metric code. The
integration test, when explicitly enabled, invokes the real checker and never
installs packages or replaces ``sherpa_onnx`` with a fake module.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECK = ROOT / "qa" / "real_asr_check.py"

sys.path.insert(0, str(ROOT / "qa"))
import real_asr_check  # noqa: E402


class RealASRMetricTests(unittest.TestCase):
    def test_normalisation_handles_case_punctuation_and_digits(self):
        self.assertEqual(
            real_asr_check._normalise_tokens("¡Pedido 427!", "es"),
            ["pedido", "cuatro", "dos", "siete"],
        )
        self.assertEqual(
            real_asr_check._normalise_tokens("Order 427.", "en"),
            ["order", "four", "two", "seven"],
        )

    def test_wer_and_essential_content_are_measured_from_real_text(self):
        reference = real_asr_check._normalise_tokens("Abre la carpeta azul", "es")
        hypothesis = real_asr_check._normalise_tokens("abre carpeta verde", "es")
        metrics = real_asr_check._content_metrics(
            reference,
            hypothesis,
            ["abre", "carpeta", "azul"],
            "es",
        )
        self.assertGreater(metrics["wer"], 0)
        self.assertEqual(metrics["essential_found"], 2)
        self.assertEqual(metrics["essential_missing"], ["azul"])

    def test_offline_and_streaming_use_strict_shared_acceptance_limits(self):
        passing = {"wer": 0.20, "essential_coverage": 0.80, "segments": 1}
        self.assertTrue(real_asr_check._offline_accepts(passing))
        self.assertTrue(real_asr_check._stream_accepts(passing))
        self.assertFalse(
            real_asr_check._offline_accepts(
                {"wer": 0.201, "essential_coverage": 0.80, "segments": 1}
            )
        )
        self.assertFalse(
            real_asr_check._stream_accepts(
                {"wer": 0.20, "essential_coverage": 0.799}
            )
        )
        failures = real_asr_check._metric_acceptance_failures(
            {"wer": 0.35, "essential_coverage": 0.50, "segments": 0},
            require_segments=True,
        )
        self.assertEqual(
            [failure["check"] for failure in failures],
            ["wer", "essential_coverage", "segments"],
        )

    def test_report_failure_records_keep_each_failed_case(self):
        failures = real_asr_check._failure_records(
            {
                "es": {
                    "offline": {
                        "status": "fail",
                        "failure_class": "acceptance",
                        "acceptance_failures": [{"check": "wer"}],
                    }
                }
            },
            {
                "es": {
                    "offline": {
                        "status": "pass",
                    }
                }
            },
        )
        self.assertEqual(len(failures), 1)
        self.assertEqual(failures[0]["language"], "es")
        self.assertEqual(failures[0]["mode"], "offline")
        self.assertEqual(failures[0]["acceptance_failures"], [{"check": "wer"}])

    def test_jsonl_parser_rejects_non_json_output(self):
        events, error = real_asr_check._parse_jsonl(b'{"type":"ready"}\nnot-json\n')
        self.assertEqual(events, [{"type": "ready"}])
        self.assertIsNotNone(error)

    def test_disposable_wave_fixture_has_a_non_aligned_tail(self):
        with tempfile.TemporaryDirectory(prefix="meetcapture-real-asr-unit-") as directory:
            path = Path(directory) / "fixture.wav"
            raw = b"\x00\x00" * (real_asr_check.STREAM_CHUNK_SAMPLES + 17)
            import wave

            with wave.open(str(path), "wb") as stream:
                stream.setnchannels(1)
                stream.setsampwidth(2)
                stream.setframerate(real_asr_check.SAMPLE_RATE)
                stream.writeframes(raw)
            _, frames = real_asr_check._read_wave(path)
            self.assertEqual(frames % real_asr_check.STREAM_CHUNK_SAMPLES, 17)

    def test_corpus_has_two_alternating_speakers_per_session(self):
        for session in real_asr_check.SESSIONS:
            self.assertEqual(len(session.utterances), 4)
            self.assertEqual([item.speaker for item in session.utterances], [0, 1, 0, 1])

    def test_product_contract_records_default_and_constructor_wiring(self):
        contract = real_asr_check._product_contract()
        self.assertTrue(contract["default_diarize_true"])
        self.assertTrue(contract["constructor_method_diarize"])
        self.assertTrue(contract["constructor_binds_script"])
        self.assertTrue(contract["constructor_uses_segments_json"])
        self.assertTrue(contract["job_calls_diarize"])


class RealASRIntegrationTest(unittest.TestCase):
    @staticmethod
    def _has_local_prerequisites() -> bool:
        try:
            real_asr_check.select_python(None, 10.0)
            real_asr_check.validate_models(Path.home() / ".whisper" / "models" / "sherpa")
            if not shutil.which("say") or not shutil.which("afconvert"):
                return False
            return True
        except (real_asr_check.PrerequisiteError, real_asr_check.CommandError, OSError):
            return False

    def test_checker_runs_the_real_local_models_and_diarizer(self):
        if not self._has_local_prerequisites():
            self.skipTest("no hay venv local con sherpa_onnx/numpy y modelos ASR/diarización completos")
        with tempfile.TemporaryDirectory(prefix="meetcapture-real-asr-test-") as directory:
            result = subprocess.run(
                [sys.executable, str(CHECK), "--artifact-dir", str(Path(directory) / "run")],
                cwd=ROOT,
                text=True,
                capture_output=True,
                timeout=900,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr[-2000:])
            report_path = Path(directory) / "run" / "report.json"
            report = json.loads(report_path.read_text(encoding="utf-8"))
            self.assertEqual(report["status"], "pass")
            self.assertTrue(report["cpu_only"])
            self.assertEqual(set(report["results"]), {"es", "en"})
            self.assertEqual(report["acceptance"]["max_wer"], 0.20)
            self.assertEqual(report["acceptance"]["min_essential_coverage"], 0.80)
            for language in ("es", "en"):
                diarization = report["results"][language]["diarization"]
                self.assertTrue(diarization["operated"])
                self.assertGreaterEqual(len(diarization["observed_speakers"]), 2)
                self.assertTrue(diarization["text_preserved"])
                silence_offline = report["silence"][language]["offline"]
                silence_streaming = report["silence"][language]["streaming"]
                self.assertEqual(silence_offline["segments"], 0)
                self.assertEqual(silence_streaming["text_events"], 0)


if __name__ == "__main__":
    unittest.main()
