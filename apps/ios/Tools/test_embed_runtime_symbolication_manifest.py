from __future__ import annotations

import argparse
import importlib.util
import pathlib
import plistlib
import shutil
import tempfile
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).with_name("embed_runtime_symbolication_manifest.py")
SPEC = importlib.util.spec_from_file_location("embed_runtime_symbolication_manifest", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


MAIN_ID = "ai.openclaw.client.J76B47MZ6V"
ARCHIVE_UUID = "6b8fdc53-16dc-4087-bd10-ae9516768439"
GIT_SHA = "143113b5a068645b51c66135855c73554655de8d"
UUIDS = [{"uuid": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "architecture": "arm64"}]


class RuntimeSymbolicationManifestTests(unittest.TestCase):
    def test_rejects_malformed_dwarfdump_output(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            executable = pathlib.Path(raw_temp) / "OpenClaw"
            executable.write_bytes(b"fixture")
            with mock.patch.object(MODULE, "run", return_value="not a UUID record\n"):
                with self.assertRaisesRegex(ValueError, "unrecognized dwarfdump"):
                    MODULE.macho_uuids(executable, "dwarfdump")

    def test_builds_exact_five_target_mapping_with_four_verified_dsyms(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.fixture(pathlib.Path(raw_temp))
            with (
                mock.patch.object(MODULE, "macho_uuids", return_value=UUIDS),
                mock.patch.object(MODULE, "run", side_effect=self.fake_dsymutil_run),
            ):
                manifest = MODULE.build_manifest(args)

            self.assertEqual(manifest["schema"], MODULE.SCHEMA)
            self.assertEqual(manifest["git_sha"], GIT_SHA)
            self.assertEqual(manifest["archive_uuid"], ARCHIVE_UUID)
            self.assertEqual(len(manifest["executables"]), 5)
            compiled = [
                item for item in manifest["executables"]
                if item["executable_role"] == "compiled_product"
            ]
            stubs = [
                item for item in manifest["executables"]
                if item["executable_role"] == "sdk_watchkit_stub"
            ]
            self.assertEqual(len(compiled), 4)
            self.assertTrue(all(item["dsym_uuids"] == item["executable_uuids"] for item in compiled))
            self.assertEqual(len(stubs), 1)
            self.assertEqual(stubs[0]["dsym_status"], "not_emitted")
            self.assertEqual(stubs[0]["dsym_uuids"], [])

    def test_rejects_generated_dsym_uuid_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.fixture(pathlib.Path(raw_temp))

            def uuids(path: pathlib.Path, _dwarfdump: str) -> list[dict[str, str]]:
                if ".dSYM" in path.as_posix():
                    return [{"uuid": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "architecture": "arm64"}]
                return UUIDS

            with (
                mock.patch.object(MODULE, "macho_uuids", side_effect=uuids),
                mock.patch.object(MODULE, "run", side_effect=self.fake_dsymutil_run),
            ):
                with self.assertRaisesRegex(ValueError, "generated dSYM UUIDs differ"):
                    MODULE.build_manifest(args)

    def test_rejects_watch_launcher_without_companion_contract(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.fixture(pathlib.Path(raw_temp))
            watch_info_path = args.app / "Watch" / "OpenClawWatchApp.app" / "Info.plist"
            watch_info = plistlib.loads(watch_info_path.read_bytes())
            watch_info["WKCompanionAppBundleIdentifier"] = "ai.openclaw.wrong"
            watch_info_path.write_bytes(plistlib.dumps(watch_info))
            with (
                mock.patch.object(MODULE, "macho_uuids", return_value=UUIDS),
                mock.patch.object(MODULE, "run", side_effect=self.fake_dsymutil_run),
            ):
                with self.assertRaisesRegex(ValueError, "companion bundle identifier mismatch"):
                    MODULE.build_manifest(args)

    def test_rejects_missing_or_extra_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.fixture(pathlib.Path(raw_temp))
            missing = args.app / "PlugIns" / "OpenClawShareExtension.appex"
            for child in missing.iterdir():
                child.unlink()
            missing.rmdir()
            with self.assertRaisesRegex(ValueError, "unexpected five-target"):
                MODULE.discover_bundles(args.app)

        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.fixture(pathlib.Path(raw_temp))
            self.write_bundle(
                args.app / "PlugIns" / "Unexpected.appex",
                f"{MAIN_ID}.unexpected",
                "Unexpected",
            )
            with self.assertRaisesRegex(ValueError, "unexpected five-target"):
                MODULE.discover_bundles(args.app)

    def test_rejects_symlinked_embedded_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            args = self.fixture(root)
            share = args.app / "PlugIns" / "OpenClawShareExtension.appex"
            external = root / "external-share.appex"
            shutil.move(share, external)
            try:
                share.symlink_to(external, target_is_directory=True)
            except OSError as error:
                self.skipTest(f"symlink creation unavailable: {error}")
            with self.assertRaisesRegex(ValueError, "not a regular directory"):
                MODULE.discover_bundles(args.app)

    def test_rejects_source_archive_and_configuration_mismatch(self) -> None:
        cases = [
            ("OpenClawBuildGitSHA", "0" * 40, "source SHA"),
            ("OpenClawBuildArchiveUUID", "12345678-1234-5678-1234-567812345678", "archive UUID"),
            ("OpenClawBuildConfiguration", "Debug", "configuration"),
        ]
        for key, replacement, expected in cases:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as raw_temp:
                args = self.fixture(pathlib.Path(raw_temp))
                info_path = args.app / "Info.plist"
                info = plistlib.loads(info_path.read_bytes())
                info[key] = replacement
                info_path.write_bytes(plistlib.dumps(info))
                with self.assertRaisesRegex(ValueError, expected):
                    MODULE.build_manifest(args)

    def test_write_is_bounded_and_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.fixture(pathlib.Path(raw_temp))
            with (
                mock.patch.object(MODULE, "macho_uuids", return_value=UUIDS),
                mock.patch.object(MODULE, "run", side_effect=self.fake_dsymutil_run),
            ):
                MODULE.write_manifest(args)
                first = args.output.read_bytes()
                MODULE.write_manifest(args)
                second = args.output.read_bytes()
            self.assertEqual(first, second)
            self.assertLessEqual(len(first), MODULE.MAXIMUM_BYTES)

    def test_rejects_manifest_larger_than_bound(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            args = self.fixture(pathlib.Path(raw_temp))
            with mock.patch.object(
                MODULE,
                "build_manifest",
                return_value={"oversized": "x" * MODULE.MAXIMUM_BYTES},
            ):
                with self.assertRaisesRegex(ValueError, "exceeds size bound"):
                    MODULE.write_manifest(args)
            self.assertFalse(args.output.exists())

    def test_failure_removes_stale_output_and_rejects_output_escape(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            root = pathlib.Path(raw_temp)
            args = self.fixture(root)
            args.output.write_text("stale", encoding="utf-8")
            with mock.patch.object(MODULE, "build_manifest", side_effect=ValueError("failed")):
                with self.assertRaisesRegex(ValueError, "failed"):
                    MODULE.write_manifest(args)
            self.assertFalse(args.output.exists())

            args.output = root / "outside.json"
            with self.assertRaisesRegex(ValueError, "escapes its controlled root"):
                MODULE.write_manifest(args)

    def fixture(self, root: pathlib.Path) -> argparse.Namespace:
        app = root / "OpenClaw.app"
        extension_ids = [f"{MAIN_ID}.activitywidget", f"{MAIN_ID}.share"]
        watch_ids = [f"{MAIN_ID}.watchkitapp", f"{MAIN_ID}.watchkitapp.extension"]
        self.write_bundle(
            app,
            MAIN_ID,
            "OpenClaw",
            {
                "OpenClawBuildGitSHA": GIT_SHA,
                "OpenClawBuildArchiveUUID": ARCHIVE_UUID,
                "OpenClawBuildConfiguration": "Release",
                "OpenClawBuildExtensionBundleIDs": extension_ids,
                "OpenClawBuildWatchBundleIDs": watch_ids,
                "CFBundleVersion": "84",
            },
        )
        self.write_bundle(
            app / "PlugIns" / "OpenClawActivityWidget.appex",
            extension_ids[0],
            "OpenClawActivityWidget",
        )
        self.write_bundle(
            app / "PlugIns" / "OpenClawShareExtension.appex",
            extension_ids[1],
            "OpenClawShareExtension",
        )
        watch_app = app / "Watch" / "OpenClawWatchApp.app"
        self.write_bundle(
            watch_app,
            watch_ids[0],
            "OpenClawWatchApp",
            {
                "WKWatchKitApp": True,
                "WKCompanionAppBundleIdentifier": MAIN_ID,
            },
        )
        self.write_bundle(
            watch_app / "PlugIns" / "OpenClawWatchExtension.appex",
            watch_ids[1],
            "OpenClawWatchExtension",
        )
        return argparse.Namespace(
            app=app,
            output=app / "AIESRuntimeSymbolicationManifest.json",
            git_sha=GIT_SHA,
            archive_uuid=ARCHIVE_UUID,
            configuration="Release",
            dwarfdump="dwarfdump",
            dsymutil="dsymutil",
            temporary_directory=root,
        )

    @staticmethod
    def write_bundle(
        path: pathlib.Path,
        bundle_id: str,
        executable_name: str,
        extra: dict[str, object] | None = None,
    ) -> None:
        path.mkdir(parents=True, exist_ok=True)
        info: dict[str, object] = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleExecutable": executable_name,
        }
        info.update(extra or {})
        (path / "Info.plist").write_bytes(plistlib.dumps(info))
        (path / executable_name).write_bytes(b"fixture-mach-o")

    @staticmethod
    def fake_dsymutil_run(command: list[str]) -> str:
        executable = pathlib.Path(command[1])
        output = pathlib.Path(command[command.index("-o") + 1])
        dsym_binary = output / "Contents" / "Resources" / "DWARF" / executable.name
        dsym_binary.parent.mkdir(parents=True, exist_ok=True)
        dsym_binary.write_bytes(b"fixture-dsym")
        return ""


if __name__ == "__main__":
    unittest.main()
