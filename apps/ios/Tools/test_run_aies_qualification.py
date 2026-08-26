from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

import run_aies_qualification as qualification


FILTER = "OpenClawTests/TalkDurableOutboxTests/example"
DESTINATION = "platform=iOS Simulator,id=00000000-0000-0000-0000-000000000000"


def enumeration_payload(*identifiers: str) -> dict[str, object]:
    return {
        "errors": [],
        "values": [
            {
                "disabledTests": [],
                "enabledTests": [
                    {
                        "identifier": f"{identifier}()",
                        "name": identifier.rsplit("/", 1)[-1],
                    }
                    for identifier in identifiers
                ],
                "testPlan": "OpenClaw",
            }
        ]
    }


def xcresult_tests(*outcomes: tuple[str, str]) -> dict[str, object]:
    return {
        "devices": [
            {
                "deviceId": "00000000-0000-0000-0000-000000000000",
                "platform": "iOS Simulator",
            }
        ],
        "testNodes": [
            {
                "children": [
                    {
                        "nodeIdentifier": f"{'/'.join(identifier.split('/')[-2:])}()",
                        "nodeType": "Test Case",
                        "result": result,
                    }
                    for identifier, result in outcomes
                ],
                "nodeType": "Test Suite",
            }
        ]
    }


def xcresult_summary(
    total: int, *, passed: int | None = None, failed: int = 0, skipped: int = 0
) -> dict[str, object]:
    passed = total if passed is None else passed
    return {
        "devicesAndConfigurations": [
            {
                "device": {
                    "deviceId": "00000000-0000-0000-0000-000000000000",
                    "platform": "iOS Simulator",
                },
                "expectedFailures": 0,
                "failedTests": failed,
                "passedTests": passed,
                "skippedTests": skipped,
            }
        ],
        "expectedFailures": 0,
        "failedTests": failed,
        "passedTests": passed,
        "result": "Passed" if failed == 0 else "Failed",
        "skippedTests": skipped,
        "totalTestCount": total,
        "testFailures": [] if failed == 0 else [{"failureText": "failed"}],
    }


class QualificationHarnessTests(unittest.TestCase):
    def make_xctestrun(self, root: pathlib.Path) -> pathlib.Path:
        products = root / "Build/Products"
        products.mkdir(parents=True)
        xctestrun = products / "OpenClaw_iphonesimulator.xctestrun"
        xctestrun.write_text("test-products", encoding="utf-8")
        return xctestrun

    def write_enumeration(
        self,
        path: pathlib.Path,
        xctestrun: pathlib.Path,
        identifiers: list[str],
        only_testing: str = FILTER,
    ) -> None:
        qualification.write_json(
            path,
            {
                "schema": qualification.ENUMERATION_SCHEMA,
                "destination": DESTINATION,
                "expectedTestCount": len(identifiers),
                "onlyTesting": only_testing,
                "productsTreeSHA256": qualification.stable_test_product_inventory(
                    xctestrun.parent, xctestrun
                )["treeSHA256"],
                "testIdentifiers": identifiers,
                "xctestrunSHA256": qualification.sha256_file(xctestrun),
            },
        )

    def write_products_manifest(
        self, path: pathlib.Path, xctestrun: pathlib.Path
    ) -> None:
        qualification.write_json(
            path,
            qualification.stable_test_product_inventory(xctestrun.parent, xctestrun),
        )

    def strict_arguments(self, root: pathlib.Path) -> list[str]:
        sources = (root / "source packages").resolve()
        cache = (root / "package cache").resolve()
        sources.mkdir(exist_ok=True)
        cache.mkdir(exist_ok=True)
        return [
            "-disableAutomaticPackageResolution",
            "-onlyUsePackageVersionsFromResolvedFile",
            "-skipPackageUpdates",
            "-disablePackageRepositoryCache",
            "-clonedSourcePackagesDirPath",
            str(sources),
            "-packageCachePath",
            str(cache),
        ]

    def test_locate_xctestrun_requires_exactly_one_regular_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            products = root / "products"
            products.mkdir()
            with self.assertRaisesRegex(
                qualification.QualificationError, "found 0"
            ):
                qualification.locate_xctestrun(products)
            first = products / "one.xctestrun"
            first.write_text("one", encoding="utf-8")
            self.assertEqual(qualification.locate_xctestrun(products), first.resolve())
            (products / "two.xctestrun").write_text("two", encoding="utf-8")
            with self.assertRaisesRegex(
                qualification.QualificationError, "found 2"
            ):
                qualification.locate_xctestrun(products)

    def test_product_inventory_is_deterministic_and_content_sensitive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            xctestrun = self.make_xctestrun(root)
            product = xctestrun.parent / "Debug-iphonesimulator/OpenClawTests.xctest/binary"
            product.parent.mkdir(parents=True)
            product.write_bytes(b"first")
            first = qualification.test_product_inventory(xctestrun.parent)
            second = qualification.test_product_inventory(xctestrun.parent)
            self.assertEqual(first, second)
            self.assertEqual(first["fileCount"], 2)
            product.write_bytes(b"second")
            changed = qualification.test_product_inventory(xctestrun.parent)
            self.assertNotEqual(first["treeSHA256"], changed["treeSHA256"])

    def test_product_inventory_rejects_external_xctestrun(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            products = root / "products"
            products.mkdir()
            external = root / "external.xctestrun"
            external.write_text("external", encoding="utf-8")
            with self.assertRaisesRegex(
                qualification.QualificationError, "inside the test-products root"
            ):
                qualification.test_product_inventory(products, external)

    def test_evidence_output_must_not_overlap_test_products(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            products = pathlib.Path(temporary) / "Build/Products"
            products.mkdir(parents=True)
            with self.assertRaisesRegex(qualification.QualificationError, "must not overlap"):
                qualification.require_separate_output(
                    products / "evidence.json", products
                )

    def test_extra_xcode_arguments_allow_only_strict_package_custody(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            strict = self.strict_arguments(root)
            arguments = qualification.validate_extra_xcode_arguments(strict)
        self.assertEqual(arguments, strict)
        for rejected in (
            ["archive"],
            ["-allowProvisioningUpdates"],
            ["CODE_SIGNING_ALLOWED=YES"],
            ["-authenticationKeyPath", "/tmp/key.p8"],
        ):
            with self.subTest(rejected=rejected):
                with self.assertRaises(qualification.QualificationError):
                    qualification.validate_extra_xcode_arguments(rejected)

    def test_extra_xcode_arguments_reject_duplicates_and_missing_values(self) -> None:
        with self.assertRaisesRegex(qualification.QualificationError, "duplicate"):
            qualification.validate_extra_xcode_arguments(
                ["-skipPackageUpdates", "-skipPackageUpdates"]
            )
        with self.assertRaisesRegex(qualification.QualificationError, "requires one value"):
            qualification.validate_extra_xcode_arguments(["-packageCachePath"])
        with self.assertRaisesRegex(qualification.QualificationError, "incomplete"):
            qualification.validate_extra_xcode_arguments([])

    def test_collect_enumeration_is_exact_for_suite_and_target(self) -> None:
        payload = enumeration_payload(
            "OpenClawTests/TalkDurableOutboxTests/example",
            "OpenClawTests/TalkDurableOutboxTests/other",
        )
        suite = qualification.collect_enumerated_identifiers(
            payload, "OpenClawTests/TalkDurableOutboxTests"
        )
        target = qualification.collect_enumerated_identifiers(payload, FILTER)
        self.assertEqual(
            suite,
            ["TalkDurableOutboxTests/example", "TalkDurableOutboxTests/other"],
        )
        self.assertEqual(target, ["TalkDurableOutboxTests/example"])

    def test_collect_enumeration_ignores_disabled_tests(self) -> None:
        payload = enumeration_payload(
            "OpenClawTests/TalkDurableOutboxTests/example"
        )
        payload["values"][0]["disabledTests"] = [
            {"identifier": "OpenClawTests/TalkDurableOutboxTests/other()"}
        ]
        self.assertEqual(
            qualification.collect_enumerated_identifiers(payload, FILTER),
            ["TalkDurableOutboxTests/example"],
        )

    def test_collect_enumeration_ignores_enabled_tests_from_other_filters(self) -> None:
        payload = enumeration_payload(
            "OpenClawTests/TalkDurableOutboxTests/example",
            "OpenClawTests/UnrelatedTests/example",
            "OtherTests/TalkDurableOutboxTests/example",
        )
        self.assertEqual(
            qualification.collect_enumerated_identifiers(payload, FILTER),
            ["TalkDurableOutboxTests/example"],
        )

    def test_verify_passing_xcresult_requires_exact_identifiers_and_counts(self) -> None:
        expected = ["TalkDurableOutboxTests/example", "TalkDurableOutboxTests/other"]
        tests = xcresult_tests(
            ("OpenClawTests/TalkDurableOutboxTests/example", "Passed"),
            ("OpenClawTests/TalkDurableOutboxTests/other", "Passed"),
        )
        report = qualification.verify_passing_xcresult(
            xcresult_summary(2), tests, expected, 2, DESTINATION
        )
        self.assertTrue(report["valid"])
        with self.assertRaisesRegex(
            qualification.QualificationError, "exact passing test count"
        ):
            qualification.verify_passing_xcresult(
                xcresult_summary(1), tests, expected, 2, DESTINATION
            )

    def test_verify_passing_xcresult_rejects_failed_or_wrong_test(self) -> None:
        expected = ["TalkDurableOutboxTests/example"]
        with self.assertRaisesRegex(qualification.QualificationError, "non-passing"):
            qualification.verify_passing_xcresult(
                xcresult_summary(1, passed=0, failed=1),
                xcresult_tests(
                    ("OpenClawTests/TalkDurableOutboxTests/example", "Failed")
                ),
                expected,
                1,
                DESTINATION,
            )
        with self.assertRaisesRegex(
            qualification.QualificationError, "differ from saved enumeration"
        ):
            qualification.verify_passing_xcresult(
                xcresult_summary(1),
                xcresult_tests(("OpenClawTests/TalkDurableOutboxTests/other", "Passed")),
                expected,
                1,
                DESTINATION,
            )

    def test_enumerate_runs_only_fixed_test_without_building_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            xctestrun = self.make_xctestrun(root)
            products_manifest = root / "products.json"
            self.write_products_manifest(products_manifest, xctestrun)
            output = root / "enumeration"
            observed: list[str] = []

            def fake_execute(
                arguments: list[str],
                process_output: pathlib.Path,
                cwd: pathlib.Path | None = None,
                *,
                timeout_seconds: int,
            ) -> qualification.ProcessOutcome:
                del cwd, timeout_seconds
                observed.extend(arguments)
                process_output.mkdir(parents=True)
                raw = pathlib.Path(
                    arguments[arguments.index("-test-enumeration-output-path") + 1]
                )
                qualification.write_json(
                    raw,
                    enumeration_payload("OpenClawTests/TalkDurableOutboxTests/example"),
                )
                return qualification.ProcessOutcome(
                    arguments,
                    101,
                    0,
                    "2026-08-26T00:00:00+00:00",
                    "2026-08-26T00:00:01+00:00",
                    False,
                )

            with mock.patch.object(
                qualification, "execute_logged", side_effect=fake_execute
            ):
                manifest = qualification.enumerate_tests(
                    xcodebuild="xcodebuild",
                    xctestrun=xctestrun,
                    destination=DESTINATION,
                    only_testing=FILTER,
                    expected_test_count=1,
                    products_manifest_path=products_manifest,
                    output=output,
                    extra_arguments=self.strict_arguments(root),
                    timeout_seconds=300,
                )
            self.assertEqual(manifest["testIdentifiers"], ["TalkDurableOutboxTests/example"])
            self.assertEqual(observed.count("test-without-building"), 1)
            self.assertIn("-enumerate-tests", observed)
            self.assertNotIn("archive", observed)
            self.assertNotIn("-allowProvisioningUpdates", observed)

    def test_run_repetitions_launches_one_fresh_process_per_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            xctestrun = self.make_xctestrun(root)
            products_manifest = root / "products.json"
            self.write_products_manifest(products_manifest, xctestrun)
            enumeration = root / "enumeration.json"
            expected = ["TalkDurableOutboxTests/example"]
            self.write_enumeration(enumeration, xctestrun, expected)
            launches: list[list[str]] = []

            def fake_execute(
                arguments: list[str],
                process_output: pathlib.Path,
                cwd: pathlib.Path | None = None,
                *,
                timeout_seconds: int,
            ) -> qualification.ProcessOutcome:
                del cwd, timeout_seconds
                launches.append(arguments)
                process_output.mkdir(parents=True)
                result = pathlib.Path(arguments[arguments.index("-resultBundlePath") + 1])
                result.mkdir()
                pid = 200 + len(launches)
                return qualification.ProcessOutcome(
                    arguments,
                    pid,
                    0,
                    f"start-{pid}",
                    f"finish-{pid}",
                    False,
                )

            with (
                mock.patch.object(
                    qualification, "execute_logged", side_effect=fake_execute
                ),
                mock.patch.object(
                    qualification,
                    "extract_xcresult",
                    return_value=(
                        xcresult_summary(1),
                        xcresult_tests(
                            ("OpenClawTests/TalkDurableOutboxTests/example", "Passed")
                        ),
                    ),
                ),
            ):
                result = qualification.run_repetitions(
                    xcodebuild="xcodebuild",
                    xcrun="xcrun",
                    xctestrun=xctestrun,
                    destination=DESTINATION,
                    only_testing=FILTER,
                    count=3,
                    expected_test_count=1,
                    enumeration_path=enumeration,
                    products_manifest_path=products_manifest,
                    output=root / "matrix",
                    extra_arguments=self.strict_arguments(root),
                    timeout_seconds=300,
                )
            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["passed"], 3)
            self.assertEqual(result["xcodebuildPIDs"], [201, 202, 203])
            self.assertEqual(len(launches), 3)
            self.assertTrue(
                all(command[-1] == "test-without-building" for command in launches)
            )
            self.assertTrue(
                all(command.count("-resultBundlePath") == 1 for command in launches)
            )

    def test_run_repetitions_stops_after_first_invalid_result(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            xctestrun = self.make_xctestrun(root)
            products_manifest = root / "products.json"
            self.write_products_manifest(products_manifest, xctestrun)
            enumeration = root / "enumeration.json"
            self.write_enumeration(
                enumeration, xctestrun, ["TalkDurableOutboxTests/example"]
            )
            launches = 0

            def fake_execute(
                arguments: list[str],
                process_output: pathlib.Path,
                cwd: pathlib.Path | None = None,
                *,
                timeout_seconds: int,
            ) -> qualification.ProcessOutcome:
                nonlocal launches
                del cwd, timeout_seconds
                launches += 1
                process_output.mkdir(parents=True)
                pathlib.Path(arguments[arguments.index("-resultBundlePath") + 1]).mkdir()
                return qualification.ProcessOutcome(
                    arguments, 300 + launches, 1, "start", "finish", False
                )

            with (
                mock.patch.object(
                    qualification, "execute_logged", side_effect=fake_execute
                ),
                mock.patch.object(
                    qualification,
                    "extract_xcresult",
                    return_value=(
                        xcresult_summary(1, passed=0, failed=1),
                        xcresult_tests(
                            ("OpenClawTests/TalkDurableOutboxTests/example", "Failed")
                        ),
                    ),
                ),
            ):
                with self.assertRaises(qualification.QualificationError):
                    qualification.run_repetitions(
                        xcodebuild="xcodebuild",
                        xcrun="xcrun",
                        xctestrun=xctestrun,
                        destination=DESTINATION,
                        only_testing=FILTER,
                        count=50,
                        expected_test_count=1,
                        enumeration_path=enumeration,
                        products_manifest_path=products_manifest,
                        output=root / "matrix",
                        extra_arguments=self.strict_arguments(root),
                        timeout_seconds=300,
                    )
            self.assertEqual(launches, 1)
            summary = qualification.read_json(
                root / "matrix/matrix-summary.json", "matrix summary"
            )
            self.assertEqual(summary["status"], "failed")
            self.assertEqual(summary["freshXcodebuildProcessCount"], 1)
            self.assertEqual(summary["firstFailure"]["iteration"], 1)

    def test_extract_xcresult_uses_xcode_26_json_commands(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            result_bundle = root / "result.xcresult"
            result_bundle.mkdir()
            outputs = [
                subprocess.CompletedProcess(
                    [], 0, json.dumps(xcresult_summary(1)), ""
                ),
                subprocess.CompletedProcess(
                    [],
                    0,
                    json.dumps(
                        xcresult_tests(
                            ("OpenClawTests/TalkDurableOutboxTests/example", "Passed")
                        )
                    ),
                    "",
                ),
            ]
            with mock.patch.object(
                qualification.subprocess, "run", side_effect=outputs
            ) as mocked:
                summary, tests = qualification.extract_xcresult(
                    "xcrun", result_bundle, root, 30
                )
            self.assertEqual(summary["totalTestCount"], 1)
            self.assertEqual(len(qualification.collect_xcresult_cases(tests)), 1)
            commands = [call.args[0] for call in mocked.call_args_list]
            self.assertEqual(commands[0][1:5], ["xcresulttool", "get", "test-results", "summary"])
            self.assertEqual(commands[1][1:5], ["xcresulttool", "get", "test-results", "tests"])

    def test_seal_evidence_is_deterministic_and_refuses_reseal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "nested").mkdir()
            (root / "a.txt").write_text("a", encoding="utf-8")
            (root / "nested/b.txt").write_text("b", encoding="utf-8")
            report = qualification.seal_evidence(root)
            sums = (root / "SHA256SUMS").read_text(encoding="utf-8")
            self.assertEqual(report["fileCount"], 2)
            self.assertEqual(
                sums.splitlines(),
                [
                    f"{qualification.sha256_file(root / 'a.txt')}  a.txt",
                    f"{qualification.sha256_file(root / 'nested/b.txt')}  nested/b.txt",
                ],
            )
            with self.assertRaisesRegex(
                qualification.QualificationError, "already sealed"
            ):
                qualification.seal_evidence(root)

    def test_load_enumeration_rejects_changed_xctestrun(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            xctestrun = self.make_xctestrun(root)
            enumeration = root / "enumeration.json"
            self.write_enumeration(
                enumeration, xctestrun, ["TalkDurableOutboxTests/example"]
            )
            xctestrun.write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(
                qualification.QualificationError, "xctestrunSHA256 differs"
            ):
                qualification.load_enumeration(
                    enumeration, xctestrun, DESTINATION, FILTER, 1
                )


if __name__ == "__main__":
    unittest.main()
