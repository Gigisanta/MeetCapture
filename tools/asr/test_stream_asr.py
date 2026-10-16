#!/usr/bin/env python3
"""Regression tests for the MeetCapture streaming ASR EOF flush."""
import contextlib
import io
import json
import os
import runpy
import sys
import tempfile
import types
import unittest


SCRIPT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "scripts", "meetcapture_stream_asr.py")
)
LOOKAHEAD_SAMPLES = 10560  # 0.66 s at 16 kHz; inference context, not capture


class FakeStream:
    def __init__(self):
        self.accepted_batches = []
        self.captured_samples = 0
        self.lookahead_samples = 0
        self.finished_calls = 0
        self.pending_decode = False
        self.endpointed = False

    def accept_waveform(self, _sample_rate, samples):
        batch = list(samples)
        self.accepted_batches.append(batch)
        if len(batch) == LOOKAHEAD_SAMPLES and all(float(sample) == 0.0 for sample in batch):
            self.lookahead_samples += len(batch)
        else:
            self.captured_samples += len(batch)
        self.pending_decode = True

    def input_finished(self):
        self.finished_calls += 1
        self.pending_decode = True


class FakeRecognizer:
    def __init__(self, endpoint_after=None, clear_on_reset=True):
        self.stream = FakeStream()
        self.endpoint_after = endpoint_after
        self.clear_on_reset = clear_on_reset

    def create_stream(self):
        return self.stream

    def is_ready(self, stream):
        return stream.pending_decode

    def decode_stream(self, stream):
        stream.pending_decode = False

    def get_result(self, stream):
        if not stream.captured_samples:
            return ""
        return "accepted:%d" % stream.captured_samples

    def is_endpoint(self, stream):
        return (
            self.endpoint_after is not None
            and not stream.endpointed
            and sum(len(batch) for batch in stream.accepted_batches) >= self.endpoint_after
        )

    def reset(self, stream):
        if self.clear_on_reset:
            stream.accepted_batches = []
            stream.captured_samples = 0
            stream.lookahead_samples = 0
        stream.endpointed = True


class ChunkedInput:
    """A byte stream that exposes PCM across arbitrary read boundaries."""

    def __init__(self, data, read_sizes):
        self.buffer = self
        self.data = data
        self.read_sizes = iter(read_sizes)
        self.offset = 0

    def read(self, _size=-1):
        if self.offset >= len(self.data):
            return b""
        try:
            size = next(self.read_sizes)
        except StopIteration:
            size = len(self.data) - self.offset
        chunk = self.data[self.offset : self.offset + size]
        self.offset += len(chunk)
        return chunk


class StreamASRTests(unittest.TestCase):
    def run_stream(
        self,
        sample_values,
        read_sizes,
        endpoint_after=None,
        clear_on_reset=True,
        raw_override=None,
        expected_exit=0,
        partial_every_ms=100000,
        chunk_ms=10,
    ):
        recognizer = FakeRecognizer(
            endpoint_after=endpoint_after, clear_on_reset=clear_on_reset
        )
        fake_sherpa = types.ModuleType("sherpa_onnx")
        fake_transcribe = types.ModuleType("transcribe_sherpa")
        fake_transcribe.MODELS_DIR = ""
        fake_transcribe.MODEL_REGISTRY = {}
        fake_transcribe.make_recognizer = lambda _model_dir: recognizer
        raw = raw_override
        if raw is None:
            raw = b"".join(
                int(value).to_bytes(2, "little", signed=True) for value in sample_values
            )

        saved = {
            "argv": sys.argv,
            "stdin": sys.stdin,
            "stdout": sys.stdout,
            "path": sys.path[:],
            "modules": {
                name: sys.modules.get(name)
                for name in ("sherpa_onnx", "transcribe_sherpa")
            },
        }
        with tempfile.TemporaryDirectory(prefix="meetcapture-asr-test-") as model_dir:
            output = io.StringIO()
            sys.argv = [
                SCRIPT,
                "--model",
                model_dir,
                "--chunk-ms",
                str(chunk_ms),
                "--partial-every-ms",
                str(partial_every_ms),
            ]
            sys.stdin = ChunkedInput(raw, read_sizes)
            sys.stdout = output
            sys.modules["sherpa_onnx"] = fake_sherpa
            sys.modules["transcribe_sherpa"] = fake_transcribe
            try:
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        runpy.run_path(SCRIPT, run_name="__main__")
                self.assertEqual(raised.exception.code, expected_exit)
            finally:
                sys.argv = saved["argv"]
                sys.stdin = saved["stdin"]
                sys.stdout = saved["stdout"]
                sys.path[:] = saved["path"]
                for name, module in saved["modules"].items():
                    if module is None:
                        sys.modules.pop(name, None)
                    else:
                        sys.modules[name] = module

        events = [json.loads(line) for line in output.getvalue().splitlines()]
        return events, recognizer

    @staticmethod
    def event_types(events):
        return [event["type"] for event in events]

    def test_subchunk_is_flushed_and_closed(self):
        values = list(range(40))
        events, recognizer = self.run_stream(values, read_sizes=[3, 7, 11, 19])

        self.assertEqual(self.event_types(events), ["ready", "final", "done"])
        self.assertEqual(events[1]["text"], "accepted:40")
        self.assertEqual(events[1]["end"], 0.003)
        self.assertEqual(events[2]["audio_sec"], 0.003)
        self.assertEqual(recognizer.stream.captured_samples, 40)
        self.assertEqual(recognizer.stream.lookahead_samples, LOOKAHEAD_SAMPLES)
        self.assertEqual(recognizer.stream.finished_calls, 1)

    def test_chunk_plus_tail_keeps_all_samples_and_time(self):
        values = list(range(192))
        events, recognizer = self.run_stream(values, read_sizes=[5, 13, 29, 47, 98])

        self.assertEqual(self.event_types(events), ["ready", "final", "done"])
        self.assertEqual(events[1]["text"], "accepted:192")
        self.assertEqual(events[1]["end"], 0.012)
        self.assertEqual(events[2]["audio_sec"], 0.012)
        self.assertEqual(recognizer.stream.captured_samples, 192)
        self.assertEqual(recognizer.stream.lookahead_samples, LOOKAHEAD_SAMPLES)
        self.assertEqual(recognizer.stream.finished_calls, 1)

    def test_endpoint_final_is_not_duplicated_at_eof(self):
        values = list(range(160))
        events, recognizer = self.run_stream(
            values,
            read_sizes=[17, 31, 53, 91],
            endpoint_after=160,
            clear_on_reset=False,
        )

        finals = [event for event in events if event["type"] == "final"]
        self.assertEqual([event["text"] for event in finals], ["accepted:160"])
        self.assertEqual([event["end"] for event in finals], [0.01])
        self.assertEqual(self.event_types(events), ["ready", "final", "done"])
        self.assertEqual(recognizer.stream.captured_samples, 160)
        self.assertEqual(recognizer.stream.lookahead_samples, 0)
        self.assertEqual(recognizer.stream.finished_calls, 1)

    def test_partial_protocol_is_preserved_before_eof_final(self):
        values = list(range(1632))
        events, recognizer = self.run_stream(
            values,
            read_sizes=[3, 7, 11, 19],
            partial_every_ms=100,
            chunk_ms=101,
        )

        self.assertEqual(self.event_types(events), ["ready", "partial", "final", "done"])
        self.assertEqual(events[1]["text"], "accepted:1616")
        self.assertEqual(events[2]["text"], "accepted:1632")
        self.assertEqual(events[2]["end"], 0.102)
        self.assertEqual(recognizer.stream.captured_samples, 1632)
        self.assertEqual(recognizer.stream.lookahead_samples, LOOKAHEAD_SAMPLES)
        self.assertEqual(recognizer.stream.finished_calls, 1)

    def test_empty_input_is_closed_without_final(self):
        events, recognizer = self.run_stream([], read_sizes=[])

        self.assertEqual(self.event_types(events), ["ready", "done"])
        self.assertEqual(events[1]["audio_sec"], 0.0)
        self.assertEqual(recognizer.stream.lookahead_samples, 0)
        self.assertEqual(recognizer.stream.finished_calls, 1)

    def test_odd_eof_is_an_error_without_final_or_done(self):
        events, recognizer = self.run_stream(
            [], read_sizes=[1], raw_override=b"\x01", expected_exit=1
        )

        self.assertEqual(self.event_types(events), ["ready", "error"])
        self.assertIn("PCM truncado al EOF", events[1]["message"])
        self.assertEqual(recognizer.stream.lookahead_samples, 0)
        self.assertEqual(recognizer.stream.finished_calls, 0)


if __name__ == "__main__":
    unittest.main()
