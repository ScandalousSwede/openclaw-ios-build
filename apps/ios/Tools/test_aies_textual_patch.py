from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import stat

import aies_textual_patch as patcher


class TextualPatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "root"
        self.packages = Path(self.temp.name) / "packages"
        self.checkout = self.packages / "checkouts/textual"
        self.checkout.mkdir(parents=True)
        self.target = self.checkout / patcher.SOURCE
        self.target.parent.mkdir(parents=True)
        self.original = b"first\nold expression\nlast\n"
        self.expected = b"first\nnew expression\nlast\n"
        self.target.write_bytes(self.original)
        self.git("init", "--quiet")
        self.git("add", ".")
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        revision = self.git("rev-parse", "HEAD").strip()
        self.patch = {"schema": "aies.ios.checkout-source-patch.v1", "packageIdentity": "textual", "repository": "https://github.com/gonzalezreal/textual", "revision": revision, "path": patcher.SOURCE, "beforeSHA256": patcher.digest(self.original), "afterSHA256": patcher.digest(self.expected), "replacement": {"before": "old expression", "after": "new expression"}, "purpose": "fixture"}
        self.manifest = {"sourcePatches": [{"packageIdentity": "textual", "path": patcher.PROVENANCE, "sha256": ""}], "pins": [{"identity": "textual", "location": self.patch["repository"], "revision": revision}]}
        self.persist_patch()
        self.state = Path(self.temp.name) / "workspace-state.json"
        self.state.write_text(json.dumps({"object": {"dependencies": [{"packageRef": {"identity": "textual"}, "subpath": "textual"}]}}))
        self.archive = Path(self.temp.name) / "archive"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.checkout, text=True)

    def persist_patch(self):
        path = self.root / patcher.PROVENANCE
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(self.patch))
        self.manifest["sourcePatches"][0]["sha256"] = patcher.digest(path.read_bytes())

    def verify(self, apply=False):
        return patcher.verify(self.root, self.manifest, self.state, self.packages, apply=apply, archive=self.archive)

    def test_preparation_archives_original_and_repeated_verification_is_read_only(self):
        first = self.verify(apply=True)
        self.assertEqual(self.target.read_bytes(), self.expected)
        self.assertEqual((self.archive / "TextBuilder-original.swift").read_bytes(), self.original)
        self.assertEqual(self.verify(), first)
        self.assertEqual(self.verify(apply=True), first)

    def test_patches_swiftpm_readonly_source_and_restores_exact_mode(self):
        self.target.chmod(0o444)
        self.verify(apply=True)
        self.assertEqual(self.target.read_bytes(), self.expected)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o444)
        self.verify()

    def test_restores_readonly_mode_after_write_failure(self):
        self.target.chmod(0o444)
        original_write = Path.write_bytes
        def fail_target(path, data):
            if path == self.target:
                self.assertTrue(path.stat().st_mode & stat.S_IWUSR)
                raise OSError("synthetic disk failure")
            return original_write(path, data)
        with mock.patch.object(Path, "write_bytes", fail_target):
            with self.assertRaisesRegex(OSError, "synthetic disk failure"):
                self.verify(apply=True)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o444)
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertEqual((self.archive / "TextBuilder-original.swift").read_bytes(), self.original)

    def test_verification_rejects_unpatched_checkout_without_mutating_it(self):
        with self.assertRaisesRegex(patcher.PatchError, "exact governed patch"):
            self.verify()
        self.assertEqual(self.target.read_bytes(), self.original)
        self.assertFalse(self.archive.exists())

    def test_refuses_unrelated_checkout_change_before_or_after_patch(self):
        for patched in (False, True):
            with self.subTest(patched=patched):
                if patched:
                    self.verify(apply=True)
                extra = self.checkout / "unexpected.swift"
                extra.write_text("unrelated")
                with self.assertRaisesRegex(patcher.PatchError, "exact governed patch"):
                    self.verify(apply=True)
                extra.unlink()

    def test_refuses_partial_or_conflicting_target_without_overwrite(self):
        self.target.write_bytes(b"partial")
        with self.assertRaisesRegex(patcher.PatchError, "exact governed patch"):
            self.verify(apply=True)
        self.assertEqual(self.target.read_bytes(), b"partial")

    def test_refuses_archive_conflict_before_mutation(self):
        self.archive.mkdir()
        (self.archive / "TextBuilder-original.swift").write_bytes(b"other")
        with self.assertRaisesRegex(patcher.PatchError, "archive conflicts"):
            self.verify(apply=True)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_rejects_changed_provenance_or_selected_pin(self):
        altered = copy.deepcopy(self.manifest)
        altered["sourcePatches"][0]["sha256"] = "0" * 64
        with self.assertRaisesRegex(patcher.PatchError, "provenance digest"):
            patcher.declaration(self.root, altered)
        altered = copy.deepcopy(self.manifest)
        altered["pins"][0]["revision"] = "0" * 40
        with self.assertRaisesRegex(patcher.PatchError, "selected dependency"):
            patcher.declaration(self.root, altered)

    def test_rejects_wrong_result_digest_before_mutation(self):
        self.patch["afterSHA256"] = "0" * 64
        self.persist_patch()
        with self.assertRaisesRegex(patcher.PatchError, "replacement digest"):
            self.verify(apply=True)
        self.assertEqual(self.target.read_bytes(), self.original)

    def test_rejects_changed_checkout_revision(self):
        self.git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "later")
        with self.assertRaisesRegex(patcher.PatchError, "revision differs"):
            self.verify(apply=True)

    def test_rejects_workspace_path_escape(self):
        self.state.write_text(json.dumps({"object": {"dependencies": [{"packageRef": {"identity": "textual"}, "subpath": "../textual"}]}}))
        with self.assertRaisesRegex(patcher.PatchError, "unsafe"):
            self.verify(apply=True)

    def test_rejects_symlink_source_without_mutating_target(self):
        outside = Path(self.temp.name) / "outside.swift"
        outside.write_bytes(self.original)
        self.target.unlink()
        self.target.symlink_to(outside)
        with self.assertRaisesRegex(patcher.PatchError, "escapes"):
            self.verify(apply=True)
        self.assertEqual(outside.read_bytes(), self.original)


if __name__ == "__main__":
    unittest.main()
