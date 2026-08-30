#!/usr/bin/env python3
"""Create and verify an exact-SHA, strict-package AIES iOS build root."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shlex
import subprocess
import sys
from typing import Any

import aies_package_authority as authority


RECEIPT_SCHEMA = "aies.ios.package-preparation.v1"
STRICT_FLAGS = (
    "-disableAutomaticPackageResolution",
    "-onlyUsePackageVersionsFromResolvedFile",
    "-skipPackageUpdates",
    "-disablePackageRepositoryCache",
)
REQUIRED_XCODEBUILD_HELP_FLAGS = (
    "-clonedSourcePackagesDirPath",
    "-disableAutomaticPackageResolution",
    "-disablePackageRepositoryCache",
    "-onlyUsePackageVersionsFromResolvedFile",
    "-packageCachePath",
    "-skipPackageUpdates",
)


class PreparationError(RuntimeError):
    """A fail-closed build-root preparation error."""


def run(
    arguments: list[str],
    *,
    cwd: pathlib.Path | None = None,
    log: pathlib.Path | None = None,
    stream: bool = False,
) -> subprocess.CompletedProcess[str]:
    if log is not None:
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text("command: " + shlex.join(arguments) + "\n", encoding="utf-8")
    if stream:
        with (log.open("a", encoding="utf-8") if log else open(os.devnull, "w")) as output:
            process = subprocess.Popen(
                arguments,
                cwd=cwd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert process.stdout is not None
            for line in process.stdout:
                print(line, end="")
                output.write(line)
            status = process.wait()
        if status != 0:
            raise subprocess.CalledProcessError(status, arguments)
        return subprocess.CompletedProcess(arguments, status, "", "")
    result = subprocess.run(
        arguments,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )
    if log is not None:
        with log.open("a", encoding="utf-8") as output:
            output.write(result.stdout)
            output.write(result.stderr)
    if result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, arguments, result.stdout, result.stderr
        )
    return result


def git(root: pathlib.Path, *arguments: str) -> str:
    return run(["git", *arguments], cwd=root).stdout


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_inventory(root: pathlib.Path) -> dict[str, Any]:
    if not root.is_dir():
        raise PreparationError(f"generated project tree is missing: {root}")
    files = []
    combined = hashlib.sha256()
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        digest = sha256(path)
        size = path.stat().st_size
        files.append({"path": relative, "sha256": digest, "bytes": size})
        combined.update(relative.encode("utf-8"))
        combined.update(b"\0")
        combined.update(digest.encode("ascii"))
        combined.update(b"\0")
    return {"treeSHA256": combined.hexdigest(), "fileCount": len(files), "files": files}


def lock_inventory(root: pathlib.Path) -> list[dict[str, Any]]:
    records = []
    for path in sorted(root.rglob("Package.resolved")):
        relative = path.relative_to(root)
        if ".git" in relative.parts or not path.is_file():
            continue
        records.append(
            {
                "path": relative.as_posix(),
                "sha256": sha256(path),
                "bytes": path.stat().st_size,
            }
        )
    return records


def assert_within(path: pathlib.Path, parent: pathlib.Path, label: str) -> pathlib.Path:
    path = path.resolve()
    parent = parent.resolve()
    try:
        path.relative_to(parent)
    except ValueError as error:
        raise PreparationError(f"{label} must stay within {parent}: {path}") from error
    if path == parent:
        raise PreparationError(f"{label} must not equal its broad parent: {path}")
    return path


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def command_identity(executable: str, arguments: list[str]) -> dict[str, Any]:
    result = run([executable, *arguments])
    return {
        "command": shlex.join([executable, *arguments]),
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def verify_xcodebuild_package_flags(
    executable: str, evidence_path: pathlib.Path
) -> dict[str, Any]:
    result = run([executable, "-help"])
    help_text = result.stdout + result.stderr
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_text(help_text, encoding="utf-8", newline="\n")
    missing = [flag for flag in REQUIRED_XCODEBUILD_HELP_FLAGS if flag not in help_text]
    if missing:
        raise PreparationError(
            "selected xcodebuild lacks required strict package flags: "
            + ", ".join(missing)
        )
    return {
        "command": shlex.join([executable, "-help"]),
        "helpSHA256": sha256(evidence_path),
        "requiredFlags": list(REQUIRED_XCODEBUILD_HELP_FLAGS),
        "allRequiredFlagsPresent": True,
    }


def strict_arguments(source_packages: pathlib.Path, package_cache: pathlib.Path) -> list[str]:
    return [
        *STRICT_FLAGS,
        "-clonedSourcePackagesDirPath",
        str(source_packages),
        "-packageCachePath",
        str(package_cache),
    ]


def write_environment(
    path: pathlib.Path,
    *,
    build_root: pathlib.Path,
    project: pathlib.Path,
    resolved: pathlib.Path,
    receipt: pathlib.Path,
    strict_args_file: pathlib.Path,
    source_packages: pathlib.Path,
    package_cache: pathlib.Path,
    semantic_sha: str,
) -> None:
    gym_build_command = shlex.join(
        [
            "xcodebuild",
            "-onlyUsePackageVersionsFromResolvedFile",
            "-skipPackageUpdates",
            "-disablePackageRepositoryCache",
            "-packageCachePath",
            str(package_cache),
        ]
    )
    values = {
        "AIES_BUILD_ROOT": str(build_root),
        "AIES_IOS_PROJECT": str(project),
        "AIES_CONCRETE_PACKAGE_RESOLVED": str(resolved),
        "AIES_PACKAGE_PREPARATION_RECEIPT": str(receipt),
        "AIES_STRICT_PACKAGE_ARGS_FILE": str(strict_args_file),
        "AIES_CLONED_SOURCE_PACKAGES": str(source_packages),
        "AIES_PACKAGE_CACHE": str(package_cache),
        "AIES_PACKAGE_SEMANTIC_SHA256": semantic_sha,
        "GYM_SKIP_PACKAGE_DEPENDENCIES_RESOLUTION": "true",
        "GYM_DISABLE_PACKAGE_AUTOMATIC_UPDATES": "true",
        "GYM_CLONED_SOURCE_PACKAGES_PATH": str(source_packages),
        # Fastlane 2.228.0 exposes no first-class Gym options for these Xcode
        # flags. Its documented xcodebuild command override is the narrow way
        # to keep archive consumption on the same already-verified cold graph.
        "GYM_XCODE_BUILD_COMMAND": gym_build_command,
    }
    invalid = [
        key
        for key, value in values.items()
        if "\n" in value or "\r" in value or "\0" in value
    ]
    if invalid:
        raise PreparationError(
            "package environment contains an unsafe multiline or NUL value: "
            + ", ".join(sorted(invalid))
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values.items()),
        encoding="utf-8",
        newline="\n",
    )


def verify_receipt(receipt_path: pathlib.Path, output: pathlib.Path | None = None) -> dict[str, Any]:
    receipt = authority.load_json(receipt_path)
    if receipt.get("schema") != RECEIPT_SCHEMA:
        raise PreparationError(f"unsupported package-preparation receipt: {receipt.get('schema')!r}")
    build_root = pathlib.Path(receipt["buildRoot"]).resolve()
    if git(build_root, "rev-parse", "HEAD").strip() != receipt["sourceSHA"]:
        raise PreparationError("prepared build root HEAD changed after preparation")
    if git(build_root, "rev-parse", "HEAD^{tree}").strip() != receipt["sourceTree"]:
        raise PreparationError("prepared build root tree changed after preparation")
    status = git(build_root, "status", "--porcelain=v2", "--untracked-files=all")
    if status:
        raise PreparationError(f"prepared build root is dirty:\n{status}")
    manifest_path = build_root / authority.DEFAULT_MANIFEST
    manifest = authority.validate_manifest(build_root, manifest_path)
    resolved = pathlib.Path(receipt["concreteResolved"]["resolvedPath"]).resolve()
    concrete = authority.validate_concrete(
        build_root, manifest, resolved, require_origin_hash=True
    )
    if concrete["rawSHA256"] != receipt["concreteResolved"]["rawSHA256"]:
        raise PreparationError("concrete Package.resolved changed after preparation")
    standalone_path = build_root / manifest["standaloneLocks"][0]["path"]
    if sha256(standalone_path) != receipt["standaloneLock"]["sha256"]:
        raise PreparationError("standalone Swabble lock changed after preparation")
    current_locks = lock_inventory(build_root)
    if current_locks != receipt["lockInventoryAfterStrictResolve"]:
        raise PreparationError("Package.resolved path or content inventory changed")
    workspace_state_path = pathlib.Path(receipt["workspaceState"]["workspaceStatePath"])
    workspace_state = authority.validate_workspace_state(manifest, workspace_state_path)
    if workspace_state["workspaceStateSHA256"] != receipt["workspaceState"]["workspaceStateSHA256"]:
        raise PreparationError("SwiftPM workspace-state changed after preparation")
    source_patch_checkout = authority.validate_source_patch_checkout(
        build_root,
        manifest,
        workspace_state_path,
        pathlib.Path(receipt["clonedSourcePackages"]).resolve(),
    )
    if source_patch_checkout != receipt["sourcePatchCheckout"]:
        raise PreparationError("ElevenLabsKit source-patch checkout changed after preparation")
    report = {
        "status": "verified",
        "sourceSHA": receipt["sourceSHA"],
        "sourceTree": receipt["sourceTree"],
        "buildRoot": str(build_root),
        "buildRootStatusPorcelainV2": status,
        "concreteResolved": concrete,
        "workspaceState": workspace_state,
        "sourcePatchCheckout": source_patch_checkout,
        "lockInventory": current_locks,
    }
    if output is not None:
        write_json(output, report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return report


def prepare(args: argparse.Namespace) -> dict[str, Any]:
    source_root = pathlib.Path(args.source_root).resolve()
    allowed_root = pathlib.Path(args.allowed_root).resolve()
    build_root = assert_within(pathlib.Path(args.build_root), allowed_root, "build root")
    evidence = assert_within(pathlib.Path(args.evidence_dir), allowed_root, "evidence directory")
    if not source_root.is_dir() or not (source_root / ".git").exists():
        raise PreparationError(f"source root is not a Git checkout: {source_root}")
    expected_sha = args.expected_sha.lower()
    if authority.HEX40.fullmatch(expected_sha) is None:
        raise PreparationError("expected SHA must be lowercase 40-hex")
    if git(source_root, "rev-parse", "HEAD").strip().lower() != expected_sha:
        raise PreparationError("source checkout does not match expected SHA")
    source_tree = git(source_root, "rev-parse", "HEAD^{tree}").strip()
    source_status = git(source_root, "status", "--porcelain=v2", "--untracked-files=all")
    if source_status:
        raise PreparationError(f"source checkout is not clean:\n{source_status}")
    if build_root.exists():
        raise PreparationError(f"build root already exists: {build_root}")
    evidence.mkdir(parents=True, exist_ok=False)

    source_manifest = authority.validate_manifest(
        source_root, source_root / authority.DEFAULT_MANIFEST
    )
    source_authority_report = {
        "manifestSHA256": sha256(source_root / authority.DEFAULT_MANIFEST),
        "semanticPinCount": len(source_manifest["pins"]),
        "sourcePatches": source_manifest["sourcePatches"],
        "standaloneLockSHA256": source_manifest["standaloneLocks"][0]["sha256"],
        "sourceStatusPorcelainV2": source_status,
    }
    write_json(evidence / "source-authority.json", source_authority_report)
    patch_evidence = evidence / "source-patches"
    patch_evidence.mkdir()
    for patch in source_manifest["sourcePatches"]:
        source = source_root / patch["path"]
        (patch_evidence / source.name).write_bytes(source.read_bytes())

    run(
        [
            "git",
            "clone",
            "--quiet",
            "--no-hardlinks",
            "--no-checkout",
            str(source_root),
            str(build_root),
        ],
        log=evidence / "clone.log",
    )
    run(
        ["git", "checkout", "--quiet", "--detach", expected_sha],
        cwd=build_root,
        log=evidence / "checkout.log",
    )
    if git(build_root, "rev-parse", "HEAD").strip().lower() != expected_sha:
        raise PreparationError("disposable build root does not match expected SHA")
    if git(build_root, "rev-parse", "HEAD^{tree}").strip() != source_tree:
        raise PreparationError("disposable build root tree differs from source tree")
    if git(build_root, "status", "--porcelain=v2", "--untracked-files=all"):
        raise PreparationError("disposable build root is dirty immediately after checkout")

    build_manifest = authority.validate_manifest(
        build_root, build_root / authority.DEFAULT_MANIFEST
    )
    ios_root = build_root / "apps/ios"
    project = build_root / build_manifest["project"]["path"]
    for pass_number in (1, 2):
        run(
            [args.xcodegen, "generate"],
            cwd=ios_root,
            log=evidence / f"xcodegen-{pass_number}.log",
            stream=True,
        )
        inventory = tree_inventory(project)
        write_json(evidence / f"xcodegen-{pass_number}-project.json", inventory)
        status = git(build_root, "status", "--porcelain=v2", "--untracked-files=all")
        (evidence / f"xcodegen-{pass_number}-status-v2.txt").write_text(
            status, encoding="utf-8"
        )
        if status:
            raise PreparationError(
                f"XcodeGen pass {pass_number} changed tracked or untracked source:\n{status}"
            )
    first_project = authority.load_json(evidence / "xcodegen-1-project.json")
    second_project = authority.load_json(evidence / "xcodegen-2-project.json")
    if first_project != second_project:
        raise PreparationError("two XcodeGen passes produced different project content")

    locks_before = lock_inventory(build_root)
    write_json(evidence / "lock-inventory-before-materialization.json", locks_before)
    concrete_path = build_root / build_manifest["project"]["concreteResolvedPath"]
    concrete = authority.materialize_concrete(build_root, build_manifest, concrete_path)
    write_json(evidence / "concrete-resolved.json", concrete)
    locks_after_materialization = lock_inventory(build_root)
    expected_paths = {record["path"] for record in locks_before} | {
        build_manifest["project"]["concreteResolvedPath"]
    }
    if {record["path"] for record in locks_after_materialization} != expected_paths:
        raise PreparationError("materialization created an unexpected Package.resolved path")
    concrete_relative = concrete_path.relative_to(build_root).as_posix()
    run(["git", "check-ignore", "-q", concrete_relative], cwd=build_root)

    source_packages = assert_within(
        allowed_root / f"{build_root.name}-source-packages",
        allowed_root,
        "cloned source packages",
    )
    package_cache = assert_within(
        allowed_root / f"{build_root.name}-package-cache",
        allowed_root,
        "package cache",
    )
    for directory in (source_packages, package_cache):
        if directory.exists():
            raise PreparationError(f"strict package directory already exists: {directory}")
        directory.mkdir(parents=True)
        if any(directory.iterdir()):
            raise PreparationError(f"strict package directory is not cold: {directory}")
    strict = strict_arguments(source_packages, package_cache)
    strict_args_file = evidence / "strict-package-args.txt"
    strict_args_file.write_text("".join(f"{item}\n" for item in strict), encoding="utf-8")
    write_json(evidence / "strict-package-args.json", strict)

    xcodebuild_help = verify_xcodebuild_package_flags(
        args.xcodebuild, evidence / "xcodebuild-help.txt"
    )
    write_json(evidence / "xcodebuild-package-flags.json", xcodebuild_help)
    toolchain = {
        "xcode": command_identity(args.xcodebuild, ["-version"]),
        "swift": command_identity(args.swift, ["--version"]),
        "xcodegen": command_identity(args.xcodegen, ["--version"]),
        "strictPackageFlagHelp": xcodebuild_help,
    }
    write_json(evidence / "toolchain.json", toolchain)
    strict_command = [
        args.xcodebuild,
        "-resolvePackageDependencies",
        "-project",
        str(project),
        "-scheme",
        build_manifest["project"]["scheme"],
        "-destination",
        args.destination,
        *strict,
    ]
    write_json(evidence / "strict-resolve-command.json", strict_command)
    before_strict_hash = concrete["rawSHA256"]
    run(
        strict_command,
        cwd=ios_root,
        log=evidence / "strict-resolve.log",
        stream=True,
    )
    concrete_after = authority.validate_concrete(
        build_root, build_manifest, concrete_path, require_origin_hash=True
    )
    if concrete_after["rawSHA256"] != before_strict_hash:
        raise PreparationError("strict resolution rewrote the concrete Package.resolved")
    standalone = build_manifest["standaloneLocks"][0]
    standalone_path = build_root / standalone["path"]
    if sha256(standalone_path) != standalone["sha256"]:
        raise PreparationError("strict resolution changed the standalone Swabble lock")

    workspace_states = sorted(source_packages.rglob("workspace-state.json"))
    if len(workspace_states) != 1:
        raise PreparationError(
            f"expected exactly one strict workspace-state.json; found {len(workspace_states)}"
        )
    workspace_state = authority.validate_workspace_state(
        build_manifest, workspace_states[0]
    )
    write_json(evidence / "workspace-state-validation.json", workspace_state)
    source_patch_checkout = authority.validate_source_patch_checkout(
        build_root,
        build_manifest,
        workspace_states[0],
        source_packages,
    )
    write_json(evidence / "source-patch-checkout.json", source_patch_checkout)
    locks_after_strict = lock_inventory(build_root)
    if locks_after_strict != locks_after_materialization:
        raise PreparationError("strict resolution changed Package.resolved path/content inventory")
    build_status = git(build_root, "status", "--porcelain=v2", "--untracked-files=all")
    if build_status:
        raise PreparationError(f"prepared build root is not clean:\n{build_status}")
    final_source_status = git(
        source_root, "status", "--porcelain=v2", "--untracked-files=all"
    )
    if final_source_status:
        raise PreparationError(f"source checkout became dirty:\n{final_source_status}")

    receipt_path = evidence / "package-preparation.json"
    receipt = {
        "schema": RECEIPT_SCHEMA,
        "sourceSHA": expected_sha,
        "sourceTree": source_tree,
        "sourceRoot": str(source_root),
        "sourceStatusPorcelainV2": final_source_status,
        "buildRoot": str(build_root),
        "buildRootStatusPorcelainV2": build_status,
        "project": str(project),
        "scheme": build_manifest["project"]["scheme"],
        "destination": args.destination,
        "manifest": str(build_root / authority.DEFAULT_MANIFEST),
        "manifestSHA256": sha256(build_root / authority.DEFAULT_MANIFEST),
        "sourcePatches": build_manifest["sourcePatches"],
        "concreteResolved": concrete_after,
        "standaloneLock": {
            "path": str(standalone_path),
            "sha256": sha256(standalone_path),
            "scope": standalone["scope"],
        },
        "workspaceState": workspace_state,
        "sourcePatchCheckout": source_patch_checkout,
        "strictArguments": strict,
        "strictResolveCommand": strict_command,
        "clonedSourcePackages": str(source_packages),
        "packageCache": str(package_cache),
        "lockInventoryBeforeMaterialization": locks_before,
        "lockInventoryAfterMaterialization": locks_after_materialization,
        "lockInventoryAfterStrictResolve": locks_after_strict,
        "xcodegenProject": second_project,
        "toolchain": toolchain,
        "securityBoundary": {
            "credentialsUsed": False,
            "signingUsed": False,
            "automaticDependencyResolutionAfterMaterialization": False,
            "packageUpdatesAllowedAfterMaterialization": False,
            "fastlanePackageDependencyResolutionSkipped": True,
        },
    }
    write_json(receipt_path, receipt)
    environment_path = evidence / "package-environment.env"
    write_environment(
        environment_path,
        build_root=build_root,
        project=project,
        resolved=concrete_path,
        receipt=receipt_path,
        strict_args_file=strict_args_file,
        source_packages=source_packages,
        package_cache=package_cache,
        semantic_sha=concrete_after["semanticSHA256"],
    )
    if args.github_env:
        github_env = pathlib.Path(args.github_env)
        with github_env.open("a", encoding="utf-8") as destination:
            destination.write(environment_path.read_text(encoding="utf-8"))
    print(json.dumps(receipt, indent=2, sort_keys=True))
    return receipt


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--source-root", required=True)
    prepare_parser.add_argument("--build-root", required=True)
    prepare_parser.add_argument("--allowed-root", required=True)
    prepare_parser.add_argument("--expected-sha", required=True)
    prepare_parser.add_argument("--evidence-dir", required=True)
    prepare_parser.add_argument("--github-env")
    prepare_parser.add_argument("--xcodegen", default="xcodegen")
    prepare_parser.add_argument("--xcodebuild", default="xcodebuild")
    prepare_parser.add_argument("--swift", default="swift")
    prepare_parser.add_argument("--destination", default="generic/platform=iOS Simulator")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--receipt", required=True)
    verify_parser.add_argument("--output")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "prepare":
            prepare(args)
        elif args.command == "verify":
            verify_receipt(
                pathlib.Path(args.receipt).resolve(),
                pathlib.Path(args.output).resolve() if args.output else None,
            )
        else:  # pragma: no cover - argparse constrains the command.
            raise PreparationError(f"unsupported command: {args.command}")
    except (
        PreparationError,
        authority.AuthorityError,
        OSError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"PACKAGE_PREPARATION_ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
