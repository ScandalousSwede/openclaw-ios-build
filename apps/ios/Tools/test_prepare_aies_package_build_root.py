from __future__ import annotations

import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock

import prepare_aies_package_build_root as preparation


class AIESPackageBuildRootPreparationTests(unittest.TestCase):
    def test_strict_arguments_are_complete_and_path_bound(self) -> None:
        source_packages = pathlib.Path("/tmp/aies source packages")
        package_cache = pathlib.Path("/tmp/aies package cache")
        arguments = preparation.strict_arguments(source_packages, package_cache)
        self.assertEqual(arguments[:4], list(preparation.STRICT_FLAGS))
        self.assertEqual(
            arguments[4:],
            [
                "-clonedSourcePackagesDirPath",
                str(source_packages),
                "-packageCachePath",
                str(package_cache),
            ],
        )

    def test_xcodebuild_help_must_expose_every_strict_flag(self) -> None:
        help_text = "\n".join(preparation.REQUIRED_XCODEBUILD_HELP_FLAGS)
        completed = subprocess.CompletedProcess(
            ["xcodebuild", "-help"], 0, help_text, ""
        )
        with tempfile.TemporaryDirectory() as temporary:
            evidence = pathlib.Path(temporary) / "xcodebuild-help.txt"
            with mock.patch.object(preparation, "run", return_value=completed):
                report = preparation.verify_xcodebuild_package_flags(
                    "xcodebuild", evidence
                )
            self.assertTrue(report["allRequiredFlagsPresent"])
            self.assertEqual(
                report["requiredFlags"],
                list(preparation.REQUIRED_XCODEBUILD_HELP_FLAGS),
            )
            self.assertEqual(evidence.read_text(encoding="utf-8"), help_text)

    def test_xcodebuild_help_rejects_missing_strict_flag(self) -> None:
        completed = subprocess.CompletedProcess(
            ["xcodebuild", "-help"], 0, "-skipPackageUpdates", ""
        )
        with tempfile.TemporaryDirectory() as temporary:
            evidence = pathlib.Path(temporary) / "xcodebuild-help.txt"
            with mock.patch.object(preparation, "run", return_value=completed):
                with self.assertRaisesRegex(
                    preparation.PreparationError,
                    "selected xcodebuild lacks required strict package flags",
                ):
                    preparation.verify_xcodebuild_package_flags(
                        "xcodebuild", evidence
                    )

    def test_fastlane_environment_uses_supported_22280_contract(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            environment = root / "environment.env"
            preparation.write_environment(
                environment,
                build_root=root / "build root",
                project=root / "build root/apps/ios/OpenClaw.xcodeproj",
                resolved=root / "build root/project/Package.resolved",
                receipt=root / "evidence/receipt.json",
                strict_args_file=root / "evidence/strict.txt",
                source_packages=root / "source packages",
                package_cache=root / "package cache",
                semantic_sha="a" * 64,
            )
            values = dict(
                line.split("=", 1)
                for line in environment.read_text(encoding="utf-8").splitlines()
            )
            self.assertEqual(values["GYM_SKIP_PACKAGE_DEPENDENCIES_RESOLUTION"], "true")
            self.assertEqual(values["GYM_DISABLE_PACKAGE_AUTOMATIC_UPDATES"], "true")
            self.assertEqual(
                values["GYM_CLONED_SOURCE_PACKAGES_PATH"], str(root / "source packages")
            )
            command = values["GYM_XCODE_BUILD_COMMAND"]
            for flag in (
                "-onlyUsePackageVersionsFromResolvedFile",
                "-skipPackageUpdates",
                "-disablePackageRepositoryCache",
                "-packageCachePath",
            ):
                self.assertEqual(command.count(flag), 1)
            self.assertNotIn("GYM_PACKAGE_CACHE_PATH", values)
            self.assertNotIn("GYM_SKIP_PACKAGE_REPOSITORY_FETCHES", values)

    def test_assert_within_rejects_parent_and_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = pathlib.Path(temporary).resolve()
            with self.assertRaisesRegex(preparation.PreparationError, "must not equal"):
                preparation.assert_within(parent, parent, "candidate")
            with self.assertRaisesRegex(preparation.PreparationError, "must stay within"):
                preparation.assert_within(parent.parent / "outside", parent, "candidate")
            child = parent / "nested"
            self.assertEqual(
                preparation.assert_within(child, parent, "candidate"), child.resolve()
            )

    def test_tree_inventory_is_deterministic_and_content_sensitive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            (root / "nested").mkdir()
            (root / "a.txt").write_text("a", encoding="utf-8")
            (root / "nested/b.txt").write_text("b", encoding="utf-8")
            first = preparation.tree_inventory(root)
            second = preparation.tree_inventory(root)
            self.assertEqual(first, second)
            (root / "nested/b.txt").write_text("changed", encoding="utf-8")
            third = preparation.tree_inventory(root)
            self.assertNotEqual(first["treeSHA256"], third["treeSHA256"])

    def test_lock_inventory_excludes_git_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            tracked = root / "apps/swabble/Package.resolved"
            metadata = root / ".git/cache/Package.resolved"
            tracked.parent.mkdir(parents=True)
            metadata.parent.mkdir(parents=True)
            tracked.write_text("tracked", encoding="utf-8")
            metadata.write_text("metadata", encoding="utf-8")
            inventory = preparation.lock_inventory(root)
            self.assertEqual(
                [record["path"] for record in inventory],
                ["apps/swabble/Package.resolved"],
            )


if __name__ == "__main__":
    unittest.main()
