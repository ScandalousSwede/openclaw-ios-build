from __future__ import annotations

import copy
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import aies_package_authority as authority


class AIESPackageAuthorityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.repo_root = pathlib.Path(__file__).resolve().parents[3]
        cls.manifest_path = cls.repo_root / authority.DEFAULT_MANIFEST
        cls.manifest = authority.validate_manifest(cls.repo_root, cls.manifest_path)

    def make_root(self, parent: pathlib.Path, name: str) -> pathlib.Path:
        root = parent / name
        paths = [
            authority.DEFAULT_MANIFEST,
            "apps/ios/PackageAuthority/elevenlabskit-observability-patch.json",
            "apps/ios/project.yml",
            "apps/shared/OpenClawKit/Package.swift",
            "apps/swabble/Package.swift",
            "apps/swabble/Package.resolved",
        ]
        for relative in paths:
            source = self.repo_root / relative
            destination = root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
        return root

    def rewrite_manifest(self, root: pathlib.Path, mutate) -> dict:
        path = root / authority.DEFAULT_MANIFEST
        payload = json.loads(path.read_text(encoding="utf-8"))
        mutate(payload)
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return payload

    def materialize(self, root: pathlib.Path) -> tuple[dict, pathlib.Path, dict]:
        manifest = authority.validate_manifest(root, root / authority.DEFAULT_MANIFEST)
        output = root / manifest["project"]["concreteResolvedPath"]
        report = authority.materialize_concrete(root, manifest, output)
        return manifest, output, report

    def assert_manifest_error(self, mutate, expected: str) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(pathlib.Path(temporary), "root")
            self.rewrite_manifest(root, mutate)
            with self.assertRaisesRegex(authority.AuthorityError, expected):
                authority.validate_manifest(root, root / authority.DEFAULT_MANIFEST)

    def assert_concrete_error(self, mutate, expected: str) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(pathlib.Path(temporary), "root")
            manifest, output, _ = self.materialize(root)
            payload = json.loads(output.read_text(encoding="utf-8"))
            mutate(payload)
            output.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(authority.AuthorityError, expected):
                authority.validate_concrete(
                    root, manifest, output, require_origin_hash=True
                )

    def source_patch_checkout_fixture(
        self, parent: pathlib.Path, *, head: str = "661d37276cda0d9e416a4966d63de4d42e72c72b"
    ) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path, object]:
        root = self.make_root(parent, "root")
        source_packages = parent / "source-packages"
        checkout = source_packages / "checkouts/ElevenLabsKit"
        checkout.mkdir(parents=True)
        workspace_state = parent / "workspace-state.json"
        workspace_state.write_text(
            json.dumps(
                {
                    "object": {
                        "dependencies": [
                            {
                                "packageRef": {"identity": "elevenlabskit"},
                                "subpath": "ElevenLabsKit",
                            }
                        ]
                    }
                }
            ),
            encoding="utf-8",
        )
        changed_paths = self.manifest["sourcePatches"][0]
        provenance = json.loads(
            (root / changed_paths["path"]).read_text(encoding="utf-8")
        )
        outputs = {
            ("rev-parse", "HEAD"): head,
            ("rev-parse", "HEAD^{tree}"): provenance["patch"]["tree"],
            ("show", "-s", "--format=%P", "HEAD"): provenance["original"]["revision"],
            (
                "rev-parse",
                f"{provenance['original']['revision']}^{{tree}}",
            ): provenance["original"]["tree"],
            ("status", "--porcelain=v2", "--untracked-files=all"): "",
            (
                "diff",
                "--name-only",
                provenance["original"]["revision"],
                provenance["patch"]["revision"],
            ): "\n".join(provenance["patch"]["changedPaths"]) + "\n",
        }

        def run_git(arguments, **options):
            command = tuple(arguments[1:])
            if command == (
                "show",
                f"{provenance['original']['revision']}:Package.swift",
            ) or command == (
                "show",
                f"{provenance['patch']['revision']}:Package.swift",
            ):
                stdout = b"package-manifest"
            elif command == (
                "diff",
                "--binary",
                provenance["original"]["revision"],
                provenance["patch"]["revision"],
            ):
                stdout = b"reviewed-binary-diff"
            else:
                stdout = outputs[command]
            if options.get("text") and isinstance(stdout, bytes):
                stdout = stdout.decode()
            return subprocess.CompletedProcess(arguments, 0, stdout, "" if options.get("text") else b"")

        return root, workspace_state, source_packages, run_git

    def test_authority_has_exact_nine_pin_graph(self) -> None:
        self.assertEqual(len(self.manifest["pins"]), 9)
        self.assertEqual(
            [pin["identity"] for pin in self.manifest["pins"]],
            [
                "commander",
                "elevenlabskit",
                "grdb.swift",
                "swift-concurrency-extras",
                "swift-syntax",
                "swift-testing",
                "swiftui-math",
                "textual",
                "webrtc",
            ],
        )

    def test_standalone_swabble_lock_remains_three_pin_authority(self) -> None:
        standalone = self.manifest["standaloneLocks"][0]
        self.assertEqual(standalone["scope"], "standalone-swabble")
        self.assertEqual(
            standalone["sha256"],
            "8db1bfc0cd61b0a2c479806004dc67ec0385d8f50c53b16edbd2df251149d7e1",
        )
        self.assertEqual(len(standalone["pinIdentities"]), 3)

    def test_elevenlabskit_observability_patch_is_exact_and_immutable(self) -> None:
        patch = self.manifest["sourcePatches"][0]
        pin = next(
            item for item in self.manifest["pins"] if item["identity"] == "elevenlabskit"
        )

        self.assertEqual(patch["packageIdentity"], "elevenlabskit")
        self.assertEqual(
            patch["sha256"],
            "abef5b643a49f9d800d5c92b00a90909794523262676dfe1f2ee8c1571f0eeb9",
        )
        self.assertEqual(
            pin["location"], "https://github.com/ScandalousSwede/ElevenLabsKit.git"
        )
        self.assertIsNone(pin["version"])
        self.assertEqual(
            pin["revision"], "661d37276cda0d9e416a4966d63de4d42e72c72b"
        )
        self.assertEqual(
            pin["requirement"],
            {
                "kind": "revision",
                "revision": "661d37276cda0d9e416a4966d63de4d42e72c72b",
            },
        )

    def test_strict_checkout_proves_exact_patch_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, workspace_state, source_packages, run_git = (
                self.source_patch_checkout_fixture(pathlib.Path(temporary))
            )

            def digest(data: bytes) -> str:
                if data == b"package-manifest":
                    return "f45bc818aec405d5f4250cff4e95619c951041b12234a984bfb10e2bdf787431"
                if data == b"reviewed-binary-diff":
                    return "6ca1cd3acb1c8d87c3fe625812578442a2f4ea99fb63c3babdcfd91b10005bf9"
                return hashlib.sha256(data).hexdigest()

            with mock.patch.object(authority.subprocess, "run", side_effect=run_git), mock.patch.object(
                authority, "sha256_bytes", side_effect=digest
            ):
                report = authority.validate_source_patch_checkout(
                    root, self.manifest, workspace_state, source_packages
                )

            self.assertEqual(report["status"], "verified")
            self.assertEqual(
                report["head"], "661d37276cda0d9e416a4966d63de4d42e72c72b"
            )
            self.assertEqual(report["tree"], "71b15c636307301515d6d1a9c158d2e98c7f1722")
            self.assertEqual(len(report["changedPaths"]), 9)

    def test_strict_checkout_rejects_wrong_patch_head(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, workspace_state, source_packages, run_git = (
                self.source_patch_checkout_fixture(
                    pathlib.Path(temporary), head="0" * 40
                )
            )
            with mock.patch.object(authority.subprocess, "run", side_effect=run_git), mock.patch.object(
                authority,
                "sha256_bytes",
                side_effect=lambda data: (
                    "f45bc818aec405d5f4250cff4e95619c951041b12234a984bfb10e2bdf787431"
                    if data == b"package-manifest"
                    else "6ca1cd3acb1c8d87c3fe625812578442a2f4ea99fb63c3babdcfd91b10005bf9"
                ),
            ):
                with self.assertRaisesRegex(
                    authority.AuthorityError, "checkout HEAD differs"
                ):
                    authority.validate_source_patch_checkout(
                        root, self.manifest, workspace_state, source_packages
                    )

    def test_source_patch_provenance_tampering_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(pathlib.Path(temporary), "root")
            patch_path = root / self.manifest["sourcePatches"][0]["path"]
            payload = json.loads(patch_path.read_text(encoding="utf-8"))
            payload["semanticDelta"]["playbackBehaviorChanged"] = False
            patch_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            manifest_path = root / authority.DEFAULT_MANIFEST
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["sourcePatches"][0]["sha256"] = hashlib.sha256(
                patch_path.read_bytes()
            ).hexdigest()
            manifest_path.write_text(
                json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(
                authority.AuthorityError, "semantic-delta contract differs"
            ):
                authority.validate_manifest(root, manifest_path)

    def test_source_patch_manifest_hash_tampering_is_rejected(self) -> None:
        self.assert_manifest_error(
            lambda value: value["sourcePatches"][0].update(sha256="0" * 64),
            "source-patch provenance changed",
        )

    def test_three_roots_are_semantically_identical_and_path_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = pathlib.Path(temporary)
            reports = []
            for index in range(3):
                root = self.make_root(parent, f"absolute-root-{index}")
                _, _, report = self.materialize(root)
                reports.append(report)
            self.assertEqual(len({report["semanticSHA256"] for report in reports}), 1)
            self.assertEqual(len({report["originHash"] for report in reports}), 3)
            self.assertEqual(len({report["rawSHA256"] for report in reports}), 3)

    def test_concrete_graph_cannot_be_reused_in_another_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = pathlib.Path(temporary)
            left = self.make_root(parent, "left")
            right = self.make_root(parent, "right")
            _, left_output, _ = self.materialize(left)
            right_manifest = authority.validate_manifest(
                right, right / authority.DEFAULT_MANIFEST
            )
            right_output = right / right_manifest["project"]["concreteResolvedPath"]
            right_output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(left_output, right_output)
            with self.assertRaisesRegex(authority.AuthorityError, "different build root"):
                authority.validate_concrete(
                    right, right_manifest, right_output, require_origin_hash=True
                )

    def test_repeated_materialization_is_byte_identical(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(pathlib.Path(temporary), "root")
            manifest, output, first = self.materialize(root)
            second = authority.materialize_concrete(root, manifest, output)
            self.assertEqual(first["rawSHA256"], second["rawSHA256"])
            self.assertEqual(first["originHash"], second["originHash"])

    def test_v4_origin_hash_formula_matches_all_recorded_roots(self) -> None:
        manifest_bytes = [
            (
                self.repo_root
                / "apps/ios/PackageAuthority/Fixtures/OpenClawKit-Package-v4.swift"
            ).read_bytes(),
            (self.repo_root / "apps/swabble/Package.swift").read_bytes(),
        ]
        cases = {
            "/Users/runner/work/_temp/aies-talk-liveness-v4-33015368816/package-graph-probes/probe-1":
                "45a0b68918e7d250761e1e7cd842532e56b9a8dcaa1f4e9bdb5245e934b78709",
            "/Users/runner/work/_temp/aies-talk-liveness-v4-33015368816/package-graph-probes/probe-2":
                "97941098cdb8c67b834f52a49a2abb1956907d4b13bbe32d5968804b212a1a6c",
            "/Users/runner/work/_temp/aies-talk-liveness-v4-33015368816/build-root":
                "757ea23d71a64ce36a315526a880a94b11efc85d9fa2c6025dd895503d0f4812",
        }
        for root, expected in cases.items():
            locations = [
                f"{root}/apps/shared/OpenClawKit",
                f"{root}/apps/swabble",
                "https://github.com/stasel/WebRTC.git",
            ]
            self.assertEqual(
                authority.compute_origin_hash_from_inputs(manifest_bytes, locations),
                expected,
            )

    def test_missing_package_is_rejected(self) -> None:
        self.assert_concrete_error(lambda value: value["pins"].pop(), "missing=.*webrtc")

    def test_extra_package_is_rejected(self) -> None:
        def mutate(value):
            extra = copy.deepcopy(value["pins"][0])
            extra["identity"] = "unexpected"
            extra["location"] = "https://github.com/example/unexpected"
            value["pins"].append(extra)

        self.assert_concrete_error(mutate, "extra=.*unexpected")

    def test_wrong_revision_is_rejected(self) -> None:
        self.assert_concrete_error(
            lambda value: value["pins"][0]["state"].update(revision="0" * 40),
            "mismatched=.*commander",
        )

    def test_wrong_version_is_rejected(self) -> None:
        self.assert_concrete_error(
            lambda value: value["pins"][0]["state"].update(version="0.2.3"),
            "mismatched=.*commander",
        )

    def test_wrong_repository_location_is_rejected(self) -> None:
        self.assert_concrete_error(
            lambda value: value["pins"][0].update(
                location="https://github.com/example/Commander.git"
            ),
            "mismatched=.*commander",
        )

    def test_repository_location_spelling_is_exact(self) -> None:
        self.assert_concrete_error(
            lambda value: value["pins"][0].update(
                location="https://github.com/steipete/Commander"
            ),
            "mismatched=.*commander",
        )

    def test_branch_requirement_is_rejected(self) -> None:
        def mutate(value):
            value["pins"][0]["state"].pop("version")
            value["pins"][0]["state"]["branch"] = "main"

        self.assert_concrete_error(mutate, "mismatched=.*commander")

    def test_checksum_mismatch_is_rejected(self) -> None:
        self.assert_concrete_error(
            lambda value: value["pins"][0]["state"].update(checksum="a" * 64),
            "mismatched=.*commander",
        )

    def test_unsupported_resolved_schema_is_rejected(self) -> None:
        self.assert_concrete_error(
            lambda value: value.update(version=4), "unsupported resolved-file schema"
        )

    def test_local_package_identity_mismatch_is_rejected(self) -> None:
        self.assert_manifest_error(
            lambda value: value["localPackages"][0].update(identity="different"),
            "unexpected local package identities",
        )

    def test_local_package_path_mismatch_is_rejected(self) -> None:
        self.assert_manifest_error(
            lambda value: value["localPackages"][0].update(
                projectRelativePath="../swabble"
            ),
            "local package path mismatch",
        )

    def test_declaration_manifest_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(pathlib.Path(temporary), "root")
            package = root / "apps/shared/OpenClawKit/Package.swift"
            package.write_text(package.read_text(encoding="utf-8") + "\n", encoding="utf-8")
            with self.assertRaisesRegex(authority.AuthorityError, "declaration/semantic-manifest drift"):
                authority.validate_manifest(root, root / authority.DEFAULT_MANIFEST)

    def test_missing_source_declaration_is_rejected(self) -> None:
        self.assert_manifest_error(
            lambda value: value["sourceDeclarations"].pop(),
            "aggregate source declaration paths differ",
        )

    def test_extra_source_declaration_is_rejected(self) -> None:
        standalone_path = self.repo_root / "apps/swabble/Package.resolved"
        standalone_digest = authority.sha256_bytes(standalone_path.read_bytes())

        def mutate(value):
            value["sourceDeclarations"].append(
                {
                    "path": "apps/swabble/Package.resolved",
                    "sha256": standalone_digest,
                }
            )

        self.assert_manifest_error(
            mutate,
            "aggregate source declaration paths differ",
        )

    def test_unknown_authority_field_is_rejected(self) -> None:
        self.assert_manifest_error(
            lambda value: value.update(unexpected=True), "fields are ambiguous"
        )

    def test_unknown_pin_state_field_is_rejected(self) -> None:
        self.assert_concrete_error(
            lambda value: value["pins"][0]["state"].update(product="Commander"),
            "unsupported fields",
        )

    def test_incoherent_exact_requirement_is_rejected(self) -> None:
        self.assert_manifest_error(
            lambda value: value["pins"][0]["requirement"].update(version="0.2.3"),
            "exact requirement does not match",
        )

    def test_incoherent_from_requirement_is_rejected(self) -> None:
        def mutate(value):
            pin = next(
                item
                for item in value["pins"]
                if item["requirement"]["kind"] == "from"
            )
            pin["requirement"]["minimumVersion"] = "999.0.0"

        self.assert_manifest_error(
            mutate,
            "outside from-requirement range",
        )

    def test_exact_revision_requirement_with_no_version_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(pathlib.Path(temporary), "root")

            def mutate(value):
                pin = value["pins"][1]
                pin["version"] = None
                pin["requirement"] = {
                    "kind": "revision",
                    "revision": pin["revision"],
                }

            self.rewrite_manifest(root, mutate)
            manifest = authority.validate_manifest(root, root / authority.DEFAULT_MANIFEST)
            state = authority.concrete_payload(root, manifest)["pins"][1]["state"]
            self.assertEqual(state, {"revision": manifest["pins"][1]["revision"]})

    def test_revision_requirement_rejects_claimed_version(self) -> None:
        def mutate(value):
            pin = value["pins"][1]
            pin["version"] = "0.1.1"

        self.assert_manifest_error(mutate, "revision requirement must not claim a version")

    def test_revision_requirement_must_match_resolved_revision(self) -> None:
        def mutate(value):
            pin = value["pins"][1]
            pin["version"] = None
            pin["requirement"] = {
                "kind": "revision",
                "revision": "0" * 40,
            }

        self.assert_manifest_error(mutate, "revision requirement does not match")

    def test_nonrevision_requirement_still_requires_version(self) -> None:
        self.assert_manifest_error(
            lambda value: value["pins"][0].update(version=None),
            "missing resolved version",
        )

    def test_malformed_version_suffix_is_rejected(self) -> None:
        self.assert_manifest_error(
            lambda value: value["pins"][0].update(version="0.2.2-not semver"),
            "unsupported semantic version",
        )

    def test_swift_prerelease_requirement_is_accepted(self) -> None:
        self.assertEqual(authority.numeric_version("603.0.0-latest"), (603, 0, 0))

    def test_workspace_state_validates_pins_and_binary_artifact(self) -> None:
        dependencies = []
        for pin in self.manifest["pins"]:
            checkout_state = {"revision": pin["revision"]}
            if pin["version"] is not None:
                checkout_state["version"] = pin["version"]
            dependencies.append(
                {
                    "basedOn": None,
                    "packageRef": {
                        "identity": pin["identity"],
                        "kind": pin["kind"],
                        "location": pin["location"],
                        "name": pin["identity"],
                    },
                    "state": {
                        "checkoutState": checkout_state,
                        "name": "sourceControlCheckout",
                    },
                    "subpath": pin["identity"],
                }
            )
        artifact = self.manifest["binaryArtifacts"][0]
        workspace = {
            "object": {
                "artifacts": [
                    {
                        "kind": {"xcframework": {}},
                        "packageRef": {
                            "identity": artifact["packageIdentity"],
                            "kind": "remoteSourceControl",
                            "location": next(
                                pin["location"]
                                for pin in self.manifest["pins"]
                                if pin["identity"] == artifact["packageIdentity"]
                            ),
                            "name": "WebRTC",
                        },
                        "path": "/tmp/WebRTC.xcframework",
                        "source": {
                            "checksum": artifact["checksum"],
                            "type": "remote",
                            "url": artifact["url"],
                        },
                        "targetName": artifact["targetName"],
                    }
                ],
                "dependencies": dependencies,
                "prebuilts": [],
            },
            "version": 7,
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "workspace-state.json"
            path.write_text(json.dumps(workspace, indent=2) + "\n", encoding="utf-8")
            report = authority.validate_workspace_state(self.manifest, path)
            self.assertEqual(report["pinCount"], 9)
            self.assertEqual(report["binaryArtifacts"], [artifact])

    def test_workspace_state_wrong_artifact_checksum_is_rejected(self) -> None:
        dependencies = []
        for pin in self.manifest["pins"]:
            checkout_state = {"revision": pin["revision"]}
            if pin["version"] is not None:
                checkout_state["version"] = pin["version"]
            dependencies.append(
                {
                    "basedOn": None,
                    "packageRef": {
                        "identity": pin["identity"],
                        "kind": pin["kind"],
                        "location": pin["location"],
                        "name": pin["identity"],
                    },
                    "state": {
                        "checkoutState": checkout_state,
                        "name": "sourceControlCheckout",
                    },
                    "subpath": pin["identity"],
                }
            )
        artifact = self.manifest["binaryArtifacts"][0]
        workspace = {
            "object": {
                "artifacts": [
                    {
                        "packageRef": {"identity": "webrtc"},
                        "source": {
                            "checksum": "0" * 64,
                            "type": "remote",
                            "url": artifact["url"],
                        },
                        "targetName": "WebRTC",
                    }
                ],
                "dependencies": dependencies,
            },
            "version": 7,
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "workspace-state.json"
            path.write_text(json.dumps(workspace), encoding="utf-8")
            with self.assertRaisesRegex(
                authority.AuthorityError,
                "WebRTC artifact URL or checksum differs",
            ):
                authority.validate_workspace_state(self.manifest, path)

    def test_materialization_provenance_is_complete(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.make_root(pathlib.Path(temporary), "root")
            _, _, report = self.materialize(root)
            self.assertEqual(report["pinCount"], 9)
            self.assertRegex(report["rawSHA256"], r"^[0-9a-f]{64}$")
            self.assertRegex(report["semanticSHA256"], r"^[0-9a-f]{64}$")
            self.assertRegex(report["originHash"], r"^[0-9a-f]{64}$")
            self.assertEqual(len(report["pins"]), 9)

    def test_openclawkit_scoped_graph_is_exact_aggregate_subset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            payload = authority.concrete_payload(self.repo_root, self.manifest)
            payload["pins"] = [
                pin
                for pin in payload["pins"]
                if pin["identity"]
                in {
                    "elevenlabskit",
                    "grdb.swift",
                    "swift-concurrency-extras",
                    "swiftui-math",
                    "textual",
                }
            ]
            resolved = root / "Package.resolved"
            resolved.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            report = authority.validate_scoped_resolved(
                self.manifest, resolved, "openclawkit"
            )
            self.assertEqual(report["pinCount"], 5)
            self.assertEqual(
                [pin["identity"] for pin in report["pins"]],
                [
                    "elevenlabskit",
                    "grdb.swift",
                    "swift-concurrency-extras",
                    "swiftui-math",
                    "textual",
                ],
            )

    def test_openclawkit_scoped_graph_rejects_extra_aggregate_pin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            payload = authority.concrete_payload(self.repo_root, self.manifest)
            payload["pins"] = [
                pin for pin in payload["pins"] if pin["identity"] != "webrtc"
            ]
            resolved = root / "Package.resolved"
            resolved.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(authority.AuthorityError, "extra=.*commander"):
                authority.validate_scoped_resolved(
                    self.manifest, resolved, "openclawkit"
                )


if __name__ == "__main__":
    unittest.main()
