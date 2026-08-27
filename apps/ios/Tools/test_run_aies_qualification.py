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


def xcresult_system_failure(message: str) -> dict[str, object]:
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
                        "children": [
                            {
                                "children": [
                                    {
                                        "name": message,
                                        "nodeType": "Failure Message",
                                    }
                                ],
                                "name": "OpenClaw encountered an error",
                                "nodeIdentifier": "OpenClaw encountered an error",
                                "nodeType": "Test Case",
                                "result": "Failed",
                            }
                        ],
                        "name": "System Failures",
                        "nodeType": "Test Suite",
                        "result": "Failed",
                    }
                ],
                "nodeType": "Unit test bundle",
                "result": "Failed",
            }
        ],
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
                "productsManifestSHA256": qualification.sha256_bytes(
                    b"products-manifest"
                ),
                "productsTreeSHA256": qualification.stable_test_product_inventory(
                    xctestrun.parent, xctestrun
                )["treeSHA256"],
                "rawTestIdentifiers": [
                    f"OpenClawTests/{identifier}()" for identifier in identifiers
                ],
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

    def test_narrow_enumeration_retains_exact_raw_xcode_selector(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            xctestrun = self.make_xctestrun(root)
            source = root / "suite-enumeration.json"
            self.write_enumeration(
                source,
                xctestrun,
                [
                    "TalkDurableOutboxTests/example",
                    "TalkDurableOutboxTests/other",
                ],
                only_testing="OpenClawTests/TalkDurableOutboxTests",
            )
            output = root / "target-enumeration.json"
            result = qualification.narrow_enumeration(
                source_path=source,
                xctestrun=xctestrun,
                destination=DESTINATION,
                source_only_testing="OpenClawTests/TalkDurableOutboxTests",
                source_expected_test_count=2,
                only_testing=FILTER,
                output=output,
            )
            raw = "OpenClawTests/TalkDurableOutboxTests/example()"
            self.assertEqual(result["onlyTesting"], raw)
            self.assertEqual(result["rawTestIdentifiers"], [raw])
            self.assertEqual(
                result["testIdentifiers"], ["TalkDurableOutboxTests/example"]
            )
            self.assertEqual(result["requestedOnlyTesting"], FILTER)
            self.assertEqual(
                result["sourceEnumerationSHA256"], qualification.sha256_file(source)
            )
            loaded = qualification.load_enumeration(
                output, xctestrun, DESTINATION, raw, 1
            )
            self.assertEqual(loaded, result)

    def test_narrow_enumeration_rejects_absent_or_wrong_suite_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            xctestrun = self.make_xctestrun(root)
            source = root / "suite-enumeration.json"
            self.write_enumeration(
                source,
                xctestrun,
                ["TalkDurableOutboxTests/example"],
                only_testing="OpenClawTests/TalkDurableOutboxTests",
            )
            with self.assertRaisesRegex(
                qualification.QualificationError, "absent or ambiguous"
            ):
                qualification.narrow_enumeration(
                    source_path=source,
                    xctestrun=xctestrun,
                    destination=DESTINATION,
                    source_only_testing="OpenClawTests/TalkDurableOutboxTests",
                    source_expected_test_count=1,
                    only_testing="OpenClawTests/TalkDurableOutboxTests/missing",
                    output=root / "missing.json",
                )
            with self.assertRaisesRegex(
                qualification.QualificationError, "must belong"
            ):
                qualification.narrow_enumeration(
                    source_path=source,
                    xctestrun=xctestrun,
                    destination=DESTINATION,
                    source_only_testing="OpenClawTests/TalkDurableOutboxTests",
                    source_expected_test_count=1,
                    only_testing="OpenClawTests/OtherTests/example",
                    output=root / "wrong-suite.json",
                )

    def test_narrow_enumeration_rejects_mismatched_raw_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            xctestrun = self.make_xctestrun(root)
            source = root / "suite-enumeration.json"
            self.write_enumeration(
                source,
                xctestrun,
                ["TalkDurableOutboxTests/example"],
                only_testing="OpenClawTests/TalkDurableOutboxTests",
            )
            payload = qualification.read_json(source, "suite enumeration")
            payload["rawTestIdentifiers"] = [
                "OpenClawTests/OtherTests/example()"
            ]
            qualification.write_json(source, payload)
            with self.assertRaisesRegex(
                qualification.QualificationError, "does not belong"
            ):
                qualification.narrow_enumeration(
                    source_path=source,
                    xctestrun=xctestrun,
                    destination=DESTINATION,
                    source_only_testing="OpenClawTests/TalkDurableOutboxTests",
                    source_expected_test_count=1,
                    only_testing=FILTER,
                    output=root / "target.json",
                )

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

    def test_verify_xcresult_preserves_simulator_system_failure(self) -> None:
        message = (
            "Failed to install or launch the test runner: Application "
            "ai.openclaw.client is installing or uninstalling"
        )
        with self.assertRaises(qualification.QualificationInfrastructureError) as raised:
            qualification.verify_passing_xcresult(
                xcresult_summary(1, passed=0, failed=1),
                xcresult_system_failure(message),
                ["TalkDurableOutboxTests/example"],
                1,
                DESTINATION,
            )
        self.assertEqual(
            raised.exception.classification, "SIMULATOR_APP_LIFECYCLE_BUSY"
        )
        self.assertIn(message, str(raised.exception))
        self.assertNotIn("invalid identifier", str(raised.exception))

    def test_system_failure_does_not_hide_an_executed_product_test(self) -> None:
        payload = xcresult_system_failure("simulator teardown failed")
        nodes = payload["testNodes"]
        assert isinstance(nodes, list)
        bundle = nodes[0]
        assert isinstance(bundle, dict)
        children = bundle["children"]
        assert isinstance(children, list)
        children.append(
            {
                "children": [
                    {
                        "nodeIdentifier": "TalkDurableOutboxTests/example()",
                        "nodeType": "Test Case",
                        "result": "Failed",
                    }
                ],
                "name": "TalkDurableOutboxTests",
                "nodeType": "Test Suite",
            }
        )
        with self.assertRaisesRegex(
            qualification.QualificationError,
            "system failure in addition to executed tests",
        ) as raised:
            qualification.verify_passing_xcresult(
                xcresult_summary(1, passed=0, failed=1),
                payload,
                ["TalkDurableOutboxTests/example"],
                1,
                DESTINATION,
            )
        self.assertNotIsInstance(
            raised.exception, qualification.QualificationInfrastructureError
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
            self.assertEqual(
                manifest["rawTestIdentifiers"],
                ["OpenClawTests/TalkDurableOutboxTests/example()"],
            )
            self.assertEqual(observed.count("test-without-building"), 1)
            self.assertIn("-enumerate-tests", observed)
            self.assertNotIn("archive", observed)
            self.assertNotIn("-allowProvisioningUpdates", observed)

    def test_reset_simulator_records_shutdown_boot_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            states = iter(("Booted", "Shutdown", "Booted"))
            commands: list[list[str]] = []

            def fake_capture(
                arguments: list[str],
                output_prefix: pathlib.Path,
                timeout_seconds: int,
            ) -> str:
                del output_prefix, timeout_seconds
                commands.append(arguments)
                if arguments[2:5] == ["list", "-j", "devices"]:
                    state = next(states)
                    payload = {
                        "devices": {
                            "com.apple.CoreSimulator.SimRuntime.iOS-18-5": [
                                {
                                    "state": state,
                                    "udid": "00000000-0000-0000-0000-000000000000",
                                }
                            ]
                        }
                    }
                    return json.dumps(payload)
                return ""

            with mock.patch.object(
                qualification, "capture_command", side_effect=fake_capture
            ):
                report = qualification.reset_simulator(
                    xcrun="xcrun",
                    destination=DESTINATION,
                    output=root / "reset",
                )
            self.assertEqual(report["stateBefore"], "Booted")
            self.assertEqual(report["stateAfterShutdown"], "Shutdown")
            self.assertEqual(report["stateAfterBoot"], "Booted")
            self.assertEqual(
                [command[2] for command in commands],
                ["list", "shutdown", "list", "boot", "bootstatus", "list"],
            )

    def test_run_repetitions_launches_one_fresh_process_per_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            xctestrun = self.make_xctestrun(root)
            products_manifest = root / "products.json"
            self.write_products_manifest(products_manifest, xctestrun)
            enumeration = root / "enumeration.json"
            expected = ["TalkDurableOutboxTests/example"]
            raw_filter = f"{FILTER}()"
            self.write_enumeration(
                enumeration, xctestrun, expected, only_testing=raw_filter
            )
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

            reset_calls: list[pathlib.Path] = []

            def fake_reset(
                *,
                xcrun: str,
                destination: str,
                output: pathlib.Path,
                timeout_seconds: int = qualification.SIMULATOR_RESET_TIMEOUT_SECONDS,
            ) -> dict[str, object]:
                del xcrun, destination, timeout_seconds
                reset_calls.append(output)
                output.mkdir(parents=True)
                report: dict[str, object] = {
                    "stateAfterBoot": "Booted",
                    "stateAfterShutdown": "Shutdown",
                    "stateBefore": "Booted",
                    "status": "passed",
                }
                qualification.write_json(output / "simulator-reset.json", report)
                return report

            with (
                mock.patch.object(
                    qualification, "execute_logged", side_effect=fake_execute
                ),
                mock.patch.object(
                    qualification,
                    "reset_simulator",
                    side_effect=fake_reset,
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
                    only_testing=raw_filter,
                    count=3,
                    expected_test_count=1,
                    enumeration_path=enumeration,
                    products_manifest_path=products_manifest,
                    output=root / "matrix",
                    extra_arguments=self.strict_arguments(root),
                    timeout_seconds=300,
                    reset_simulator_before_each_run=True,
                )
            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["passed"], 3)
            self.assertEqual(result["xcodebuildPIDs"], [201, 202, 203])
            self.assertEqual(len(launches), 3)
            self.assertEqual(len(reset_calls), 3)
            self.assertTrue(result["simulatorResetBeforeEachRun"])
            self.assertTrue(
                all(command[-1] == "test-without-building" for command in launches)
            )
            self.assertTrue(
                all(command.count("-resultBundlePath") == 1 for command in launches)
            )
            self.assertTrue(
                all(
                    command.count(f"-only-testing:{raw_filter}") == 1
                    for command in launches
                )
            )

    def test_main_enumerate_does_not_forward_run_only_simulator_reset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            arguments_file = root / "xcode-arguments.txt"
            arguments_file.write_text(
                "\n".join(self.strict_arguments(root)) + "\n", encoding="utf-8"
            )
            with (
                mock.patch.object(
                    qualification,
                    "enumerate_tests",
                    return_value={"schema": qualification.ENUMERATION_SCHEMA},
                ) as mocked,
                mock.patch("builtins.print"),
            ):
                status = qualification.main(
                    [
                        "enumerate",
                        "--xctestrun",
                        str(root / "tests.xctestrun"),
                        "--destination",
                        DESTINATION,
                        "--only-testing",
                        FILTER,
                        "--expected-test-count",
                        "1",
                        "--products-manifest",
                        str(root / "products.json"),
                        "--timeout-seconds",
                        "300",
                        "--output",
                        str(root / "enumeration"),
                        "--xcode-args-file",
                        str(arguments_file),
                    ]
                )

            self.assertEqual(status, 0)
            self.assertNotIn(
                "reset_simulator_before_each_run", mocked.call_args.kwargs
            )

    def test_main_run_forwards_simulator_reset_flag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            arguments_file = root / "xcode-arguments.txt"
            arguments_file.write_text(
                "\n".join(self.strict_arguments(root)) + "\n", encoding="utf-8"
            )
            with (
                mock.patch.object(
                    qualification,
                    "run_repetitions",
                    return_value={"schema": qualification.MATRIX_SCHEMA},
                ) as mocked,
                mock.patch("builtins.print"),
            ):
                status = qualification.main(
                    [
                        "run",
                        "--xctestrun",
                        str(root / "tests.xctestrun"),
                        "--destination",
                        DESTINATION,
                        "--only-testing",
                        FILTER,
                        "--count",
                        "1",
                        "--expected-test-count",
                        "1",
                        "--enumeration",
                        str(root / "enumeration.json"),
                        "--products-manifest",
                        str(root / "products.json"),
                        "--timeout-seconds",
                        "300",
                        "--output",
                        str(root / "matrix"),
                        "--reset-simulator-before-each-run",
                        "--xcode-args-file",
                        str(arguments_file),
                    ]
                )

            self.assertEqual(status, 0)
            self.assertTrue(mocked.call_args.kwargs["reset_simulator_before_each_run"])

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
