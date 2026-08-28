from __future__ import annotations

import hashlib
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

    stub, mode, valid, report, manifest, sentinel = map(pathlib.Path, sys.argv[1:])
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
    if not manifest.is_file():
        raise SystemExit(73)
    try:
        manifest_payload = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        raise SystemExit(74)
    readiness = manifest_payload.get("distribution_readiness")
    verification = manifest_payload.get("final_distribution_verification")
    if (
        manifest_payload.get("artifact_stage") != "EXPORTED_IPA_POST_EXPORT"
        or readiness
        != {
            "status": "VERIFIED_POST_EXPORT",
            "final_distribution_verified": True,
            "upload_eligible": True,
        }
        or not isinstance(verification, dict)
        or verification.get("status") != "exported_ipa_distribution_verified"
        or verification.get("receipt_file_name") != report.name
        or verification.get("receipt_sha256")
        != __import__("hashlib").sha256(report.read_bytes()).hexdigest()
        or verification.get("verifier_replayed_against_current_artifacts") is not True
        or not isinstance(verification.get("ipa_sha256"), str)
        or len(verification["ipa_sha256"]) != 64
    ):
        raise SystemExit(75)
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

            def manifest_for(report_name: str) -> dict[str, object]:
                return {
                    "artifact_stage": "EXPORTED_IPA_POST_EXPORT",
                    "distribution_readiness": {
                        "status": "VERIFIED_POST_EXPORT",
                        "final_distribution_verified": True,
                        "upload_eligible": True,
                    },
                    "final_distribution_verification": {
                        "status": "exported_ipa_distribution_verified",
                        "receipt_file_name": report_name,
                        "receipt_sha256": hashlib.sha256(
                            valid_path.read_bytes()
                        ).hexdigest(),
                        "verifier_replayed_against_current_artifacts": True,
                        "ipa_sha256": "1" * 64,
                    },
                }

            for mode in ("nonzero", "crash", "missing", "malformed", "partial"):
                with self.subTest(mode=mode):
                    report = root / f"{mode}-report.json"
                    manifest = root / f"{mode}-manifest.json"
                    manifest.write_text(
                        json.dumps(
                            manifest_for(report.name), indent=2, sort_keys=True
                        )
                        + "\n",
                        encoding="utf-8",
                    )
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
                            str(manifest),
                            str(sentinel),
                        ],
                        check=False,
                        cwd=pathlib.Path(__file__).parent,
                        env=environment,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(sentinel.exists())

            manifest_cases: dict[str, object] = {
                "missing": None,
                "malformed": "not-json\n",
                "archive-stage": {
                    **manifest_for("valid-report.json"),
                    "artifact_stage": "ARCHIVE_PRE_EXPORT",
                },
                "unsigned-stage": {
                    **manifest_for("valid-report.json"),
                    "artifact_stage": "UNSIGNED_ARCHIVE_QUALIFICATION",
                },
                "not-ready": {
                    **manifest_for("valid-report.json"),
                    "distribution_readiness": {
                        "status": "NOT_FINAL_PRE_EXPORT",
                        "final_distribution_verified": False,
                        "upload_eligible": False,
                    },
                },
                "wrong-receipt": {
                    **manifest_for("valid-report.json"),
                    "final_distribution_verification": {
                        **manifest_for("valid-report.json")[
                            "final_distribution_verification"
                        ],
                        "receipt_sha256": "0" * 64,
                    },
                },
                "receipt-not-replayed": {
                    **manifest_for("valid-report.json"),
                    "final_distribution_verification": {
                        **manifest_for("valid-report.json")[
                            "final_distribution_verification"
                        ],
                        "verifier_replayed_against_current_artifacts": False,
                    },
                },
            }
            for mode, payload in manifest_cases.items():
                with self.subTest(manifest_mode=mode):
                    report = root / "valid-report.json"
                    manifest = root / f"manifest-{mode}.json"
                    sentinel = root / f"manifest-{mode}-upload-sentinel"
                    manifest.unlink(missing_ok=True)
                    if isinstance(payload, str):
                        manifest.write_text(payload, encoding="utf-8")
                    elif payload is not None:
                        manifest.write_text(
                            json.dumps(payload, indent=2, sort_keys=True) + "\n",
                            encoding="utf-8",
                        )
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
                            str(manifest),
                            str(sentinel),
                        ],
                        check=False,
                        cwd=pathlib.Path(__file__).parent,
                        env=environment,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(sentinel.exists())

            report = root / "valid-report.json"
            manifest = root / "valid-manifest.json"
            manifest.write_text(
                json.dumps(manifest_for(report.name), indent=2, sort_keys=True)
                + "\n",
                encoding="utf-8",
            )
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
                    str(manifest),
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
