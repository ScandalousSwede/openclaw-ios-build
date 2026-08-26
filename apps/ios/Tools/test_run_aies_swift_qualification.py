from __future__ import annotations

import argparse
import json
import pathlib
import tempfile
import unittest
from unittest import mock

import run_aies_swift_qualification as qualification


class SwiftQualificationTests(unittest.TestCase):
    def test_summary_requires_exact_counts(self) -> None:
        log = "\x1b[32mTest run with 99 tests in 1 suite passed after 5.769 seconds.\x1b[0m\n"
        self.assertEqual(
            qualification.parse_pass_summary(log, 99, 1),
            {"tests": 99, "suites": 1},
        )
        with self.assertRaisesRegex(qualification.QualificationError, "count mismatch"):
            qualification.parse_pass_summary(log, 1, 1)

    def test_summary_rejects_missing_or_failed_summary(self) -> None:
        for value in ("", "Test run with 1 test in 1 suite failed after 0.1 seconds."):
            with self.subTest(value=value), self.assertRaises(
                qualification.QualificationError
            ):
                qualification.parse_pass_summary(value, 1, 1)

    def test_product_inventory_is_deterministic_and_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            products = root / "products"
            products.mkdir()
            (products / "binary").write_bytes(b"one")
            first = qualification.product_inventory(products)
            self.assertEqual(first, qualification.product_inventory(products))
            (products / "binary").write_bytes(b"two")
            self.assertNotEqual(first, qualification.product_inventory(products))
            try:
                (products / "link").symlink_to(products / "binary")
            except OSError:
                return
            with self.assertRaisesRegex(qualification.QualificationError, "symlink"):
                qualification.product_inventory(products)

    def test_output_must_not_overlap_package_or_products(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw).resolve()
            package = root / "package"
            products = package / ".build"
            products.mkdir(parents=True)
            for output in (root, package, products, products / "evidence"):
                with self.subTest(output=output), self.assertRaises(
                    qualification.QualificationError
                ):
                    qualification.assert_disjoint(output, [package, products])

    def test_matrix_launches_one_fresh_process_per_iteration(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            package = root / "package"
            products = package / ".build"
            products.mkdir(parents=True)
            (products / "test-binary").write_bytes(b"fixed")
            resolved = package / "Package.resolved"
            resolved.write_text("{}", encoding="utf-8")
            manifest = root / "products.json"
            qualification.write_json(manifest, qualification.product_inventory(products))
            pids = iter((101, 102, 103))

            def fake_execute(arguments, log_path, timeout_seconds):
                del arguments, timeout_seconds
                log_path.write_text(
                    "Test run with 1 test in 1 suite passed after 0.1 seconds.\n",
                    encoding="utf-8",
                )
                return {
                    "pid": next(pids),
                    "status": 0,
                    "timedOut": False,
                    "startedAt": "start",
                    "finishedAt": "finish",
                }

            args = argparse.Namespace(
                swift="swift",
                package_path=str(package),
                products_root=str(products),
                products_manifest=str(manifest),
                resolved=str(resolved),
                filter="ChatViewModelTests/example",
                count=3,
                expected_test_count=1,
                expected_suite_count=1,
                timeout_seconds=30,
                output=str(root / "evidence"),
            )
            with mock.patch.object(qualification, "execute", side_effect=fake_execute):
                report = qualification.run_matrix(args)
            self.assertEqual(report["passed"], 3)
            self.assertEqual(report["freshSwiftProcessCount"], 3)

    def test_matrix_stops_on_first_failure(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = pathlib.Path(raw)
            package = root / "package"
            products = package / ".build"
            products.mkdir(parents=True)
            (products / "test-binary").write_bytes(b"fixed")
            resolved = package / "Package.resolved"
            resolved.write_text("{}", encoding="utf-8")
            manifest = root / "products.json"
            qualification.write_json(manifest, qualification.product_inventory(products))
            args = argparse.Namespace(
                swift="swift",
                package_path=str(package),
                products_root=str(products),
                products_manifest=str(manifest),
                resolved=str(resolved),
                filter="ChatViewModelTests/example",
                count=50,
                expected_test_count=1,
                expected_suite_count=1,
                timeout_seconds=30,
                output=str(root / "evidence"),
            )
            outcome = {
                "pid": 201,
                "status": 1,
                "timedOut": False,
                "startedAt": "start",
                "finishedAt": "finish",
            }
            with (
                mock.patch.object(qualification, "execute", return_value=outcome),
                self.assertRaises(qualification.QualificationError),
            ):
                qualification.run_matrix(args)
            summary = json.loads(
                (root / "evidence/matrix-summary.json").read_text(encoding="utf-8")
            )
            self.assertEqual(summary["attempted"], 1)
            self.assertEqual(summary["passed"], 0)


if __name__ == "__main__":
    unittest.main()
