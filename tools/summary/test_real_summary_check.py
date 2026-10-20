#!/usr/bin/env python3
"""Unit checks for the opt-in real summary integration harness.

These tests are deliberately offline.  They validate the gate that decides
whether a real run may be called PASS; they do not substitute for executing
``real_summary_check.py`` against the local gateway.
"""
from __future__ import annotations

import html
import importlib.util
import io
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SCRIPT = Path(__file__).with_name("real_summary_check.py")
spec = importlib.util.spec_from_file_location("real_summary_check", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class RealSummaryCheckTests(unittest.TestCase):
    def valid_output(self):
        return {
            "meetingId": "real-summary-fixture",
            "dry_run": False,
            "summary_model": "maat/smart",
            "resumen": ["Se aprobó API v2."],
            "action_items": [
                "Lucía enviará el presupuesto final a Ana el 30 de septiembre de 2026.",
                "Bruno preparará la demo técnica para el 2 de octubre de 2026.",
            ],
            "decisiones": ["Usar la API v2 y publicar el 5 de octubre."],
            "asistentes": ["Ana", "Bruno", "Lucía"],
        }

    def rendered(self, output, transcript):
        values = output["action_items"] + output["decisiones"] + output["asistentes"]
        return "<html>" + "".join(html.escape(value) for value in values) + html.escape(transcript) + "</html>"

    def test_valid_payload_is_accepted_by_content_gate(self):
        output = self.valid_output()
        transcript = module.TRANSCRIPT
        errors = module.validate_summary_payload(
            output,
            self.rendered(output, transcript),
            transcript,
            "maat/smart",
        )
        self.assertEqual(errors, [])

    def test_dry_run_is_never_accepted(self):
        output = self.valid_output()
        output["dry_run"] = True
        errors = module.validate_summary_payload(
            output,
            self.rendered(output, module.TRANSCRIPT),
            module.TRANSCRIPT,
            "maat/smart",
        )
        self.assertTrue(any("dry_run" in error for error in errors))

    def test_missing_responsible_action_is_rejected(self):
        output = self.valid_output()
        output["action_items"][0] = "Enviar el presupuesto final el 30 de septiembre."
        errors = module.validate_summary_payload(
            output,
            self.rendered(output, module.TRANSCRIPT),
            module.TRANSCRIPT,
            "maat/smart",
        )
        self.assertTrue(any("responsable/contenido" in error for error in errors))

    def test_rich_action_dates_are_checked_on_the_matching_person_and_topic(self):
        output = self.valid_output()
        output["action_items"] = [
            "Lucía enviará el presupuesto final a Ana el 2 de octubre de 2026.",
            "Bruno preparará la demo técnica para el 30 de septiembre de 2026.",
        ]
        errors = module.validate_summary_payload(
            output,
            self.rendered(output, module.TRANSCRIPT),
            module.TRANSCRIPT,
            "maat/smart",
        )
        self.assertGreaterEqual(sum("fecha incorrecta" in error for error in errors), 2)

    def test_api_v2_does_not_count_as_the_day_two_date(self):
        output = self.valid_output()
        output["action_items"][1] = "Bruno preparará la demo técnica para API v2."
        errors = module.validate_summary_payload(
            output,
            self.rendered(output, module.TRANSCRIPT),
            module.TRANSCRIPT,
            "maat/smart",
        )
        self.assertTrue(any("fecha incorrecta" in error for error in errors))

    def test_poc_requires_reference_actions_without_assigning_a_name(self):
        transcript = "Esta es una reunión de prueba. Mañana vamos a revisar el proyecto y preparar el informe."
        output = {
            "dry_run": False,
            "summary_model": "maat/smart",
            "resumen": ["Mañana se revisará el proyecto y se preparará el informe."],
            "action_items": ["Revisar el proyecto mañana", "Preparar el informe mañana"],
            "decisiones": [],
            "asistentes": [],
        }
        rendered = self.rendered(output, transcript)
        self.assertEqual(
            module.validate_poc_summary_payload(output, rendered, transcript, "maat/smart"),
            [],
        )

    def test_poc_rejects_an_invented_assignee(self):
        transcript = "Esta es una reunión de prueba. Mañana vamos a revisar el proyecto y preparar el informe."
        output = {
            "dry_run": False,
            "summary_model": "maat/smart",
            "resumen": ["Mañana se revisará el proyecto y se preparará el informe."],
            "action_items": ["Carlos preparará el informe mañana", "Revisar el proyecto mañana"],
            "decisiones": [],
            "asistentes": [],
        }
        rendered = self.rendered(output, transcript)
        errors = module.validate_poc_summary_payload(output, rendered, transcript, "maat/smart")
        self.assertTrue(any("exactamente" in error for error in errors))

    def test_poc_requires_empty_attendees_and_rejects_name_colon_actions(self):
        transcript = "Esta es una reunión de prueba. Mañana vamos a revisar el proyecto y preparar el informe."
        output = {
            "dry_run": False,
            "summary_model": "maat/smart",
            "resumen": ["Mañana se revisará el proyecto y se preparará el informe."],
            "action_items": [
                "Lucía: preparar el informe mañana",
                "Revisar el proyecto mañana",
            ],
            "decisiones": [],
            "asistentes": ["Lucía"],
        }
        rendered = self.rendered(output, transcript)
        errors = module.validate_poc_summary_payload(output, rendered, transcript, "maat/smart")
        self.assertTrue(any("asistentes=[]" in error for error in errors))
        self.assertTrue(any("exactamente" in error for error in errors))

    def test_fixture_root_must_be_under_tmp_or_system_temp(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            with self.assertRaises(module.FixtureError):
                module._existing_fixture(Path("/"), Path(temp_dir), "maat/smart")

    def test_missing_artifact_is_reported_without_raising(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            error = module._artifact_changed(Path(temp_dir) / "missing.json", b"{}", "segunda ejecución")
        self.assertIn("ausente", error)

    def test_failure_report_accepts_existing_fixture_bases(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            fixture = {"meetings": Path(temp_dir), "bases": ["meet-a", "meet-b"]}
            output = io.StringIO()
            with redirect_stdout(output):
                module._report_failure(fixture, module.RunResult(1, "", ""), ["fallo"])
        self.assertIn("fallo", output.getvalue())

    def test_synthetic_failure_stops_before_reading_missing_artifacts(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fixture = {
                "root": root,
                "meetings": root,
                "base": "broken",
                "transcript": root / "missing.txt",
                "audio": root / "missing.m4a",
            }
            args = SimpleNamespace(model="maat/smart", fixture_dir=None, keep_audio=True)
            with mock.patch.object(module, "check_gateway", return_value={}), \
                    mock.patch.object(module, "_make_fixture", return_value=fixture), \
                    mock.patch.object(module, "run_dispatcher", return_value=module.RunResult(1, "", "")), \
                    mock.patch.object(module, "_read_summary", return_value=(None, None)), \
                    mock.patch.object(module, "_artifact_changed", side_effect=AssertionError("artifact read")), \
                    mock.patch.object(module, "_report_failure") as report:
                with redirect_stdout(io.StringIO()):
                    result = module._run_check(args)
        self.assertEqual(result, module.CHECK_FAILED)
        report.assert_called_once()

    def test_gpu_hold_detection_requires_an_explicit_active_signal(self):
        self.assertFalse(module.active_gpu_hold({"status": "ok", "tiers": {"general": {"idle_s": 12}}}))
        self.assertFalse(module.active_gpu_hold({"gpu_hold": False}))
        self.assertTrue(module.active_gpu_hold({"gpu_hold": True}))
        self.assertTrue(module.active_gpu_hold({"turns": {"hold_s": 3}}))

    def test_model_aliases_include_nested_gateway_aliases(self):
        payload = {"data": [{"id": "maat/general", "maat": {"aliases": ["maat/smart"]}}]}
        self.assertEqual(module.model_names(payload), {"maat/general", "maat/smart"})

    def test_gateway_urls_are_loopback_and_never_backend_ports(self):
        self.assertEqual(module.GATEWAY_BASE, "http://127.0.0.1:8080/v1")
        self.assertEqual(module.HEALTH_URL, "http://127.0.0.1:8080/health")
        self.assertNotIn(":180", module.GATEWAY_BASE)
        self.assertNotIn(":180", module.HEALTH_URL)


if __name__ == "__main__":
    unittest.main(verbosity=2)
