from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

import test_verify_aies_internal_signing as signing_tests
import verify_aies_internal_signing as verifier


GATE_DRIVER = textwrap.dedent(
    """
    import json
    import pathlib
    import subprocess
    import sys

    import verify_aies_internal_signing as verifier

    stub, mode, valid, report, sentinel = map(pathlib.Path, sys.argv[1:])
    report.unlink(missing_ok=True)
    sentinel.unlink(missing_ok=True)
    result = subprocess.run(
        [sys.executable, str(stub), str(mode), str(valid), str(report)],
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(result.returncode)
    if not report.is_file():
        raise SystemExit(70)
    try:
        payload = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise SystemExit(71)
    try:
        verifier.validate_report_contract(payload, archive_only=False)
    except (KeyError, TypeError, ValueError):
        raise SystemExit(72)
    sentinel.write_text("UPLOAD_REACHED\\n", encoding="utf-8")
    """
)


VERIFIER_STUB = textwrap.dedent(
    """
    import json
    import os
    import pathlib
    import signal
    import sys

    mode = sys.argv[1]
    valid = pathlib.Path(sys.argv[2])
    output = pathlib.Path(sys.argv[3])
    if mode == "nonzero":
        raise SystemExit(23)
    if mode == "crash":
        os.kill(os.getpid(), signal.SIGTERM)
    if mode == "missing":
        raise SystemExit(0)
    if mode == "malformed":
        output.write_text("not-json\\n", encoding="utf-8")
        raise SystemExit(0)
    payload = json.loads(valid.read_text(encoding="utf-8"))
    if mode == "partial":
        payload["binary_binding"]["auxiliary_code_objects"].clear()
    elif mode != "valid":
        raise SystemExit(64)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\\n", encoding="utf-8"
    )
    """
)


class AIESReleaseGateBehaviorTests(unittest.TestCase):
    def test_stage_b_receipt_is_a_behavioral_upload_gate(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            helper = signing_tests.AIESInternalSigningTests()
            args = helper.make_fixture(root / "fixture")
            with helper.mock_signing():
                valid = verifier.build_report(args)
            valid_path = root / "valid.json"
            valid_path.write_text(
                json.dumps(valid, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            driver = root / "gate_driver.py"
            stub = root / "verifier_stub.py"
            driver.write_text(GATE_DRIVER, encoding="utf-8")
            stub.write_text(VERIFIER_STUB, encoding="utf-8")

            for mode in ("nonzero", "crash", "missing", "malformed", "partial"):
                with self.subTest(mode=mode):
                    report = root / f"{mode}-report.json"
                    sentinel = root / f"{mode}-upload-sentinel"
                    environment = dict(os.environ)
                    environment["PYTHONPATH"] = str(pathlib.Path(__file__).parent)
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(driver),
                            str(stub),
                            mode,
                            str(valid_path),
                            str(report),
                            str(sentinel),
                        ],
                        check=False,
                        cwd=pathlib.Path(__file__).parent,
                        env=environment,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(sentinel.exists())

            report = root / "valid-report.json"
            sentinel = root / "valid-upload-sentinel"
            environment = dict(os.environ)
            environment["PYTHONPATH"] = str(pathlib.Path(__file__).parent)
            result = subprocess.run(
                [
                    sys.executable,
                    str(driver),
                    str(stub),
                    "valid",
                    str(valid_path),
                    str(report),
                    str(sentinel),
                ],
                check=False,
                cwd=pathlib.Path(__file__).parent,
                env=environment,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "UPLOAD_REACHED\n")


if __name__ == "__main__":
    unittest.main()
