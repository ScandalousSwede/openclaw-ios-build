from __future__ import annotations

import hashlib
import json
import pathlib
import tempfile
import unittest
import uuid

import cleanup_aies_export_profiles as cleaner
import test_verify_aies_internal_signing as fixtures
import verify_aies_internal_signing as verifier


class ExportProfileCleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        fixture = fixtures.AIESInternalSigningTests()
        args = fixture.make_fixture(self.root / "fixture")
        with fixture.mock_signing():
            self.report = verifier.build_report(args)
        self.profile = b"synthetic distribution profile"
        for bundle in self.report["ipa"]["bundles"]:
            bundle["profile"]["uuid"] = str(uuid.uuid4())
            bundle["profile"]["embedded_profile_sha256"] = hashlib.sha256(self.profile).hexdigest()
        self.uuid = self.report["ipa"]["bundles"][0]["profile"]["uuid"]
        self.report_path = self.root / "report.json"
        self.report_path.write_text(json.dumps(self.report))
        self.home = self.root / "home"
        self.caches = [self.home.joinpath(*parts) for parts in cleaner.CACHES]
        for cache in self.caches:
            cache.mkdir(parents=True)

    def test_export_profiles_in_both_caches_are_removed_idempotently(self) -> None:
        for cache in self.caches:
            (cache / f"{self.uuid.upper()}.mobileprovision").write_bytes(self.profile)
        self.assertEqual(cleaner.cleanup(self.report_path, self.home), 2)
        self.assertEqual(cleaner.cleanup(self.report_path, self.home), 0)

    def test_unrelated_profiles_are_preserved(self) -> None:
        path = self.caches[0] / "unrelated.mobileprovision"
        path.write_bytes(self.profile)
        self.assertEqual(cleaner.cleanup(self.report_path, self.home), 0)
        self.assertEqual(path.read_bytes(), self.profile)

    def test_changed_profile_is_preserved_and_cleanup_fails(self) -> None:
        path = self.caches[0] / f"{self.uuid}.mobileprovision"
        path.write_bytes(b"different profile")
        with self.assertRaisesRegex(ValueError, "differs"):
            cleaner.cleanup(self.report_path, self.home)
        self.assertEqual(path.read_bytes(), b"different profile")

    def test_profile_symlink_is_rejected_without_touching_target(self) -> None:
        target = self.root / "shared-profile"
        target.write_bytes(self.profile)
        (self.caches[0] / f"{self.uuid}.mobileprovision").symlink_to(target)
        with self.assertRaises(OSError):
            cleaner.cleanup(self.report_path, self.home)
        self.assertEqual(target.read_bytes(), self.profile)

    def test_missing_receipt_preserves_profiles_after_failed_export(self) -> None:
        path = self.caches[0] / f"{self.uuid}.mobileprovision"
        path.write_bytes(self.profile)
        self.report_path.unlink()
        self.assertEqual(cleaner.cleanup(self.report_path, self.home), 0)
        self.assertTrue(path.exists())

    def test_unverified_receipt_cannot_authorize_cleanup(self) -> None:
        path = self.caches[0] / f"{self.uuid}.mobileprovision"
        path.write_bytes(self.profile)
        self.report["status"] = "failed"
        self.report_path.write_text(json.dumps(self.report))
        with self.assertRaises(ValueError):
            cleaner.cleanup(self.report_path, self.home)
        self.assertTrue(path.exists())


if __name__ == "__main__":
    unittest.main()
