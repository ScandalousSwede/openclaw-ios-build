#!/usr/bin/env python3
"""Validate and materialize the AIES aggregate iOS Swift package graph."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
from typing import Any
from urllib.parse import urlsplit


SCHEMA = "aies.ios.aggregate-package-authority.v2"
DEFAULT_MANIFEST = "apps/ios/PackageAuthority/aggregate-package-graph.json"
HEX40 = re.compile(r"[0-9a-f]{40}")
HEX64 = re.compile(r"[0-9a-f]{64}")
SEMANTIC_VERSION = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


class AuthorityError(ValueError):
    """A fail-closed package-authority validation error."""


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode()


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuthorityError(f"unable to load JSON at {path}: {error}") from error
    if not isinstance(payload, dict):
        raise AuthorityError(f"expected a JSON object at {path}")
    return payload


def repo_path(root: pathlib.Path, relative: str) -> pathlib.Path:
    if not relative or pathlib.PurePosixPath(relative).is_absolute():
        raise AuthorityError(f"repository path must be relative: {relative!r}")
    candidate = (root / pathlib.PurePosixPath(relative)).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as error:
        raise AuthorityError(f"repository path escapes the root: {relative!r}") from error
    return candidate


def canonical_location(location: Any) -> str:
    if not isinstance(location, str) or not location:
        raise AuthorityError("package location must be a non-empty string")
    parsed = urlsplit(location)
    if (
        parsed.scheme.lower() != "https"
        or parsed.hostname is None
        or parsed.hostname.lower() != "github.com"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise AuthorityError(f"package location is not a canonical public GitHub URL: {location!r}")
    parts = [part for part in parsed.path.split("/") if part]
    if len(parts) != 2:
        raise AuthorityError(f"package location must identify one GitHub repository: {location!r}")
    owner, repository = parts
    if repository.lower().endswith(".git"):
        repository = repository[:-4]
    if not owner or not repository:
        raise AuthorityError(f"package location is incomplete: {location!r}")
    return f"https://github.com/{owner.lower()}/{repository.lower()}"


def _require_exact_keys(payload: dict[str, Any], expected: set[str], label: str) -> None:
    observed = set(payload)
    if observed != expected:
        raise AuthorityError(
            f"{label} fields are ambiguous: missing={sorted(expected - observed)}, "
            f"extra={sorted(observed - expected)}"
        )


def _validate_requirement(requirement: Any, label: str) -> None:
    if not isinstance(requirement, dict):
        raise AuthorityError(f"{label} requirement must be an object")
    kind = requirement.get("kind")
    if kind == "exact":
        _require_exact_keys(requirement, {"kind", "version"}, f"{label} exact requirement")
        if not isinstance(requirement["version"], str) or not requirement["version"]:
            raise AuthorityError(f"{label} exact version is invalid")
        numeric_version(requirement["version"])
    elif kind == "from":
        _require_exact_keys(
            requirement, {"kind", "minimumVersion"}, f"{label} from requirement"
        )
        if not isinstance(requirement["minimumVersion"], str) or not requirement["minimumVersion"]:
            raise AuthorityError(f"{label} minimum version is invalid")
        numeric_version(requirement["minimumVersion"])
    elif kind == "revision":
        _require_exact_keys(
            requirement, {"kind", "revision"}, f"{label} revision requirement"
        )
        if (
            not isinstance(requirement["revision"], str)
            or HEX40.fullmatch(requirement["revision"]) is None
        ):
            raise AuthorityError(f"{label} exact revision is invalid")
    else:
        raise AuthorityError(f"{label} uses unsupported requirement kind: {kind!r}")


def validate_manifest(root: pathlib.Path, manifest_path: pathlib.Path) -> dict[str, Any]:
    payload = load_json(manifest_path)
    _require_exact_keys(
        payload,
        {
            "schema",
            "resolvedFileSchemaVersion",
            "project",
            "sourceDeclarations",
            "sourcePatches",
            "standaloneLocks",
            "localPackages",
            "originHash",
            "binaryArtifacts",
            "pins",
        },
        "aggregate authority",
    )
    if payload.get("schema") != SCHEMA:
        raise AuthorityError(f"unsupported aggregate authority schema: {payload.get('schema')!r}")
    if payload.get("resolvedFileSchemaVersion") != 3:
        raise AuthorityError("aggregate authority requires resolved-file schema version 3")

    project = payload["project"]
    if not isinstance(project, dict):
        raise AuthorityError("project authority must be an object")
    _require_exact_keys(project, {"path", "scheme", "concreteResolvedPath"}, "project")
    if project["path"] != "apps/ios/OpenClaw.xcodeproj" or project["scheme"] != "OpenClaw":
        raise AuthorityError("aggregate authority targets an unexpected project or scheme")
    concrete = project["concreteResolvedPath"]
    expected_concrete = (
        "apps/ios/OpenClaw.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/"
        "Package.resolved"
    )
    if concrete != expected_concrete:
        raise AuthorityError("aggregate concrete resolved path is not project-scoped")

    declarations = payload["sourceDeclarations"]
    if not isinstance(declarations, list) or not declarations:
        raise AuthorityError("sourceDeclarations must be a non-empty array")
    declaration_paths: set[str] = set()
    for index, declaration in enumerate(declarations):
        if not isinstance(declaration, dict):
            raise AuthorityError(f"source declaration {index} must be an object")
        _require_exact_keys(declaration, {"path", "sha256"}, f"source declaration {index}")
        path = declaration["path"]
        digest = declaration["sha256"]
        if path in declaration_paths:
            raise AuthorityError(f"duplicate source declaration: {path}")
        declaration_paths.add(path)
        if not isinstance(digest, str) or HEX64.fullmatch(digest) is None:
            raise AuthorityError(f"invalid source declaration SHA-256 for {path}")
        source = repo_path(root, path)
        if not source.is_file():
            raise AuthorityError(f"source declaration is missing: {path}")
        actual = sha256_bytes(source.read_bytes())
        if actual != digest:
            raise AuthorityError(
                f"package declaration/semantic-manifest drift at {path}: "
                f"expected {digest}, observed {actual}"
            )
    expected_declaration_paths = {
        "apps/ios/project.yml",
        "apps/shared/OpenClawKit/Package.swift",
        "apps/swabble/Package.swift",
    }
    if declaration_paths != expected_declaration_paths:
        raise AuthorityError(
            "aggregate source declaration paths differ: "
            f"missing={sorted(expected_declaration_paths - declaration_paths)}, "
            f"extra={sorted(declaration_paths - expected_declaration_paths)}"
        )

    source_patches = payload["sourcePatches"]
    if not isinstance(source_patches, list) or len(source_patches) != 1:
        raise AuthorityError("aggregate authority requires exactly one governed source patch")
    source_patch = source_patches[0]
    if not isinstance(source_patch, dict):
        raise AuthorityError("source patch authority must be an object")
    _require_exact_keys(
        source_patch, {"packageIdentity", "path", "sha256"}, "source patch authority"
    )
    if source_patch["packageIdentity"] != "elevenlabskit":
        raise AuthorityError("unexpected governed source-patch package identity")
    if source_patch["path"] != (
        "apps/ios/PackageAuthority/elevenlabskit-observability-patch.json"
    ):
        raise AuthorityError("unexpected ElevenLabsKit source-patch provenance path")
    if not isinstance(source_patch["sha256"], str) or HEX64.fullmatch(
        source_patch["sha256"]
    ) is None:
        raise AuthorityError("invalid ElevenLabsKit source-patch provenance SHA-256")
    source_patch_path = repo_path(root, source_patch["path"])
    if not source_patch_path.is_file():
        raise AuthorityError("ElevenLabsKit source-patch provenance is missing")
    source_patch_digest = sha256_bytes(source_patch_path.read_bytes())
    if source_patch_digest != source_patch["sha256"]:
        raise AuthorityError(
            "ElevenLabsKit source-patch provenance changed: "
            f"expected {source_patch['sha256']}, observed {source_patch_digest}"
        )
    provenance = load_json(source_patch_path)
    _require_exact_keys(
        provenance,
        {
            "schema",
            "packageIdentity",
            "purpose",
            "original",
            "patch",
            "semanticDelta",
            "truthfulObservationLimits",
            "rollback",
        },
        "ElevenLabsKit source-patch provenance",
    )
    if provenance["schema"] != "aies.ios.package-source-patch.v1":
        raise AuthorityError("unsupported ElevenLabsKit source-patch provenance schema")
    if provenance["packageIdentity"] != "elevenlabskit" or provenance["purpose"] != (
        "diagnostic_playback_observability_pcm_stream_integrity_and_teardown_ownership"
    ):
        raise AuthorityError("ElevenLabsKit source-patch purpose or identity differs")
    expected_original = {
        "repository": "https://github.com/steipete/ElevenLabsKit.git",
        "tag": "0.1.1",
        "revision": "0f1e4c039bd0e22b03c0cb7f43c00c1865858f0b",
        "tree": "3a8eeeb4938a2ec30c46f3a90762187b2ca40fa6",
    }
    if provenance["original"] != expected_original:
        raise AuthorityError("ElevenLabsKit original 0.1.1 provenance differs")
    expected_patch = {
        "repository": "https://github.com/ScandalousSwede/ElevenLabsKit.git",
        "revision": "e8d1d2d663a4302aca82d28fc87fad0343fa0bde",
        "tree": "b95a2ccf5abcfc44e7470f55bf246034ec7f4a34",
        "changedPaths": [
            "Sources/ElevenLabsKit/PCMPlayerNode.swift",
            "Sources/ElevenLabsKit/PCMStreamingAudioPlayer.swift",
            "Sources/ElevenLabsKit/PlaybackObservation.swift",
            "Sources/ElevenLabsKit/StreamingAudioPlayback.swift",
            "Sources/ElevenLabsKit/StreamingAudioPlayer.swift",
            "Tests/ElevenLabsKitTests/PCMStreamingAudioPlayerFinishTests.swift",
            "Tests/ElevenLabsKitTests/PCMStreamingAudioPlayerTests.swift",
            "Tests/ElevenLabsKitTests/PlaybackObservationTests.swift",
            "Tests/ElevenLabsKitTests/StreamingAudioPlaybackTests.swift",
        ],
    }
    if provenance["patch"] != expected_patch:
        raise AuthorityError("ElevenLabsKit immutable patch provenance differs")
    expected_semantic_delta = {
        "observerOptional": True,
        "observerDefault": "no_op",
        "applicationBehaviorDependsOnObserver": False,
        "playbackBehaviorChanged": True,
        "networkingBehaviorChanged": False,
        "decodingBehaviorChanged": False,
        "bufferingBehaviorChanged": True,
        "routingBehaviorChanged": False,
        "cancellationBehaviorChanged": True,
        "fallbackBehaviorChanged": False,
        "errorBehaviorChanged": True,
        "transitiveDependenciesAdded": [],
    }
    if provenance["semanticDelta"] != expected_semantic_delta:
        raise AuthorityError("ElevenLabsKit patch semantic-delta contract differs")
    expected_limits = [
        "ElevenLabsKit PCM and MP3 paths expose no direct first-render callback",
        "AudioQueue running state is not treated as first-render evidence",
        "AudioFileStreamOpen is parser creation and is not emitted as decoder creation",
        "physical audibility is not observable",
    ]
    if provenance["truthfulObservationLimits"] != expected_limits:
        raise AuthorityError("ElevenLabsKit truthful-observation limits differ")
    expected_rollback = {
        "packageRepository": "https://github.com/steipete/ElevenLabsKit.git",
        "requirement": {"kind": "from", "minimumVersion": "0.1.1"},
        "resolvedVersion": "0.1.1",
        "resolvedRevision": "0f1e4c039bd0e22b03c0cb7f43c00c1865858f0b",
        "resolvedTree": "3a8eeeb4938a2ec30c46f3a90762187b2ca40fa6",
    }
    if provenance["rollback"] != expected_rollback:
        raise AuthorityError("ElevenLabsKit patch rollback contract differs")

    standalone_locks = payload["standaloneLocks"]
    if not isinstance(standalone_locks, list) or len(standalone_locks) != 1:
        raise AuthorityError("exactly one standalone lock authority is expected")
    standalone = standalone_locks[0]
    if not isinstance(standalone, dict):
        raise AuthorityError("standalone lock authority must be an object")
    _require_exact_keys(
        standalone, {"scope", "path", "sha256", "pinIdentities"}, "standalone lock"
    )
    if standalone["scope"] != "standalone-swabble":
        raise AuthorityError("unexpected standalone lock scope")
    standalone_path = repo_path(root, standalone["path"])
    if not standalone_path.is_file():
        raise AuthorityError("standalone Swabble lock is missing")
    standalone_digest = sha256_bytes(standalone_path.read_bytes())
    if standalone_digest != standalone["sha256"]:
        raise AuthorityError(
            f"standalone Swabble lock changed: expected {standalone['sha256']}, "
            f"observed {standalone_digest}"
        )
    standalone_payload = load_json(standalone_path)
    standalone_identities = sorted(
        pin.get("identity") for pin in standalone_payload.get("pins", []) if isinstance(pin, dict)
    )
    if standalone_identities != sorted(standalone["pinIdentities"]):
        raise AuthorityError("standalone Swabble lock pins do not match its scoped authority")

    local_packages = payload["localPackages"]
    if not isinstance(local_packages, list) or len(local_packages) != 2:
        raise AuthorityError("aggregate authority requires exactly two local packages")
    local_identities: set[str] = set()
    for index, package in enumerate(local_packages):
        if not isinstance(package, dict):
            raise AuthorityError(f"local package {index} must be an object")
        _require_exact_keys(
            package,
            {"identity", "projectRelativePath", "repositoryPath", "declaration"},
            f"local package {index}",
        )
        identity = package["identity"]
        if not isinstance(identity, str) or identity.lower() != identity or not identity:
            raise AuthorityError(f"local package {index} identity is invalid")
        if identity in local_identities:
            raise AuthorityError(f"duplicate local package identity: {identity}")
        local_identities.add(identity)
        repository_path = repo_path(root, package["repositoryPath"])
        if not (repository_path / "Package.swift").is_file():
            raise AuthorityError(f"local package manifest is missing: {package['repositoryPath']}")
        project_root = repo_path(root, "apps/ios")
        resolved_relative = (project_root / package["projectRelativePath"]).resolve()
        if resolved_relative != repository_path:
            raise AuthorityError(f"local package path mismatch for {identity}")
    if local_identities != {"openclawkit", "swabble"}:
        raise AuthorityError(f"unexpected local package identities: {sorted(local_identities)}")

    origin = payload["originHash"]
    if not isinstance(origin, dict):
        raise AuthorityError("originHash contract must be an object")
    _require_exact_keys(
        origin,
        {"contract", "upstreamCommit", "manifestPathsInOrder", "dependencyLocationsInOrder"},
        "originHash contract",
    )
    if origin["contract"] != "swiftpm-6.2.3-workspace-root":
        raise AuthorityError("unsupported originHash contract")
    if origin["upstreamCommit"] != "9e5bde0a18e8be5b978cdcd4e4a3ac4565237191":
        raise AuthorityError("unexpected SwiftPM originHash implementation commit")
    if origin["manifestPathsInOrder"] != [
        "apps/shared/OpenClawKit/Package.swift",
        "apps/swabble/Package.swift",
    ]:
        raise AuthorityError("originHash manifest ordering is ambiguous")
    locations = origin["dependencyLocationsInOrder"]
    expected_locations = [
        {"kind": "absoluteRepositoryPath", "path": "apps/shared/OpenClawKit"},
        {"kind": "absoluteRepositoryPath", "path": "apps/swabble"},
        {"kind": "literal", "value": "https://github.com/stasel/WebRTC.git"},
    ]
    if locations != expected_locations:
        raise AuthorityError("originHash dependency-location ordering is ambiguous")

    artifacts = payload["binaryArtifacts"]
    if not isinstance(artifacts, list) or len(artifacts) != 1:
        raise AuthorityError("aggregate authority requires exactly one binary artifact")
    artifact = artifacts[0]
    if not isinstance(artifact, dict):
        raise AuthorityError("binary artifact authority must be an object")
    _require_exact_keys(
        artifact,
        {"packageIdentity", "targetName", "url", "checksumAlgorithm", "checksum"},
        "binary artifact",
    )
    if artifact != {
        "packageIdentity": "webrtc",
        "targetName": "WebRTC",
        "url": (
            "https://github.com/stasel/WebRTC/releases/download/147.0.0/"
            "WebRTC-M147.xcframework.zip"
        ),
        "checksumAlgorithm": "sha256",
        "checksum": "49f9b1713432c19f408e3218fc8526c7692fafca5869f7ec5f5991614276ed40",
    }:
        raise AuthorityError("WebRTC binary artifact URL or checksum differs from authority")
    canonical_location(artifact["url"].split("/releases/", 1)[0])

    pins = payload["pins"]
    if not isinstance(pins, list) or len(pins) != 9:
        raise AuthorityError("aggregate semantic authority must contain exactly nine pins")
    pin_identities: set[str] = set()
    for index, pin in enumerate(pins):
        if not isinstance(pin, dict):
            raise AuthorityError(f"pin {index} must be an object")
        _require_exact_keys(
            pin,
            {
                "identity",
                "kind",
                "location",
                "version",
                "revision",
                "branch",
                "checksum",
                "aggregateRole",
                "declarationRole",
                "sourceDeclaration",
                "requirement",
            },
            f"pin {index}",
        )
        identity = pin["identity"]
        if not isinstance(identity, str) or not identity or identity.lower() != identity:
            raise AuthorityError(f"pin {index} identity is invalid")
        if identity in pin_identities:
            raise AuthorityError(f"duplicate package identity: {identity}")
        pin_identities.add(identity)
        if pin["kind"] != "remoteSourceControl":
            raise AuthorityError(f"unsupported package kind for {identity}: {pin['kind']!r}")
        canonical_location(pin["location"])
        _validate_requirement(pin["requirement"], identity)
        requirement = pin["requirement"]
        if requirement["kind"] == "revision":
            if pin["version"] is not None:
                raise AuthorityError(f"revision requirement must not claim a version for {identity}")
        else:
            if not isinstance(pin["version"], str) or not pin["version"]:
                raise AuthorityError(f"missing resolved version for {identity}")
            numeric_version(pin["version"])
        if not isinstance(pin["revision"], str) or HEX40.fullmatch(pin["revision"]) is None:
            raise AuthorityError(f"invalid resolved revision for {identity}")
        if pin["branch"] is not None:
            raise AuthorityError(f"branch-based package is not authorized: {identity}")
        if pin["checksum"] is not None:
            raise AuthorityError(f"unexpected package checksum for source-control pin: {identity}")
        if pin["aggregateRole"] not in {"direct", "transitive"}:
            raise AuthorityError(f"invalid aggregate role for {identity}")
        if pin["declarationRole"] not in {"direct", "transitive"}:
            raise AuthorityError(f"invalid declaration role for {identity}")
        if not isinstance(pin["sourceDeclaration"], str) or not pin["sourceDeclaration"]:
            raise AuthorityError(f"missing declaration provenance for {identity}")
        if requirement["kind"] == "exact" and requirement["version"] != pin["version"]:
            raise AuthorityError(f"exact requirement does not match resolved version for {identity}")
        if requirement["kind"] == "from":
            minimum = numeric_version(requirement["minimumVersion"])
            resolved = numeric_version(pin["version"])
            if resolved < minimum or resolved[0] != minimum[0]:
                raise AuthorityError(
                    f"resolved version falls outside from-requirement range for {identity}"
                )
        if requirement["kind"] == "revision" and requirement["revision"] != pin["revision"]:
            raise AuthorityError(f"revision requirement does not match resolved revision for {identity}")
    expected_identities = {
        "commander",
        "elevenlabskit",
        "grdb.swift",
        "swift-concurrency-extras",
        "swift-syntax",
        "swift-testing",
        "swiftui-math",
        "textual",
        "webrtc",
    }
    if pin_identities != expected_identities:
        raise AuthorityError(
            f"aggregate package identities differ: missing={sorted(expected_identities - pin_identities)}, "
            f"extra={sorted(pin_identities - expected_identities)}"
        )
    if [pin["identity"] for pin in pins] != sorted(pin_identities):
        raise AuthorityError("aggregate package pins must use deterministic identity ordering")
    elevenlabs_pin = next(pin for pin in pins if pin["identity"] == "elevenlabskit")
    if elevenlabs_pin["location"] != provenance["patch"]["repository"] or (
        elevenlabs_pin["revision"] != provenance["patch"]["revision"]
    ):
        raise AuthorityError("ElevenLabsKit semantic pin differs from governed patch provenance")
    return payload


def compute_origin_hash_from_inputs(
    manifest_contents: list[bytes], dependency_locations: list[str]
) -> str:
    content = bytearray()
    for data in manifest_contents:
        content.extend(data)
    for location in dependency_locations:
        content.extend(location.encode("utf-8"))
    return sha256_bytes(bytes(content))


def numeric_version(value: str) -> tuple[int, int, int]:
    match = SEMANTIC_VERSION.fullmatch(value)
    if match is None:
        raise AuthorityError(f"unsupported semantic version: {value!r}")
    return tuple(int(part) for part in match.groups())


def compute_origin_hash(root: pathlib.Path, manifest: dict[str, Any]) -> str:
    origin = manifest["originHash"]
    manifest_contents = [
        repo_path(root, relative).read_bytes()
        for relative in origin["manifestPathsInOrder"]
    ]
    dependency_locations = []
    for location in origin["dependencyLocationsInOrder"]:
        if location["kind"] == "absoluteRepositoryPath":
            value = str(repo_path(root, location["path"]))
        elif location["kind"] == "literal":
            value = location["value"]
        else:
            raise AuthorityError(f"unsupported originHash location kind: {location['kind']!r}")
        dependency_locations.append(value)
    return compute_origin_hash_from_inputs(manifest_contents, dependency_locations)


def semantic_pins_from_manifest(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "identity": pin["identity"],
            "kind": pin["kind"],
            "location": pin["location"],
            "canonicalLocation": canonical_location(pin["location"]),
            "version": pin["version"],
            "revision": pin["revision"],
            "branch": pin["branch"],
            "checksum": pin["checksum"],
        }
        for pin in manifest["pins"]
    ]


def semantic_pins_from_resolved(payload: dict[str, Any], label: str) -> list[dict[str, Any]]:
    pins = payload.get("pins")
    if not isinstance(pins, list):
        raise AuthorityError(f"{label} pins must be an array")
    observed: list[dict[str, Any]] = []
    identities: set[str] = set()
    for index, pin in enumerate(pins):
        if not isinstance(pin, dict):
            raise AuthorityError(f"{label} pin {index} must be an object")
        _require_exact_keys(
            pin, {"identity", "kind", "location", "state"}, f"{label} pin {index}"
        )
        state = pin["state"]
        if not isinstance(state, dict):
            raise AuthorityError(f"{label} pin {index} state must be an object")
        allowed_state_keys = {"version", "revision", "branch", "checksum"}
        if not set(state).issubset(allowed_state_keys):
            raise AuthorityError(
                f"{label} pin {index} state contains unsupported fields: "
                f"{sorted(set(state) - allowed_state_keys)}"
            )
        identity = pin["identity"]
        if not isinstance(identity, str) or identity.lower() != identity or not identity:
            raise AuthorityError(f"{label} pin {index} identity is invalid")
        if identity in identities:
            raise AuthorityError(f"duplicate {label} package identity: {identity}")
        identities.add(identity)
        observed.append(
            {
                "identity": identity,
                "kind": pin["kind"],
                "location": pin["location"],
                "canonicalLocation": canonical_location(pin["location"]),
                "version": state.get("version"),
                "revision": state.get("revision"),
                "branch": state.get("branch"),
                "checksum": state.get("checksum"),
            }
        )
    observed.sort(key=lambda pin: pin["identity"])
    return observed


def compare_semantic_pins(
    observed: list[dict[str, Any]],
    expected: list[dict[str, Any]],
    label: str,
) -> None:
    if observed == expected:
        return
    observed_by_id = {pin["identity"]: pin for pin in observed}
    expected_by_id = {pin["identity"]: pin for pin in expected}
    missing = sorted(set(expected_by_id) - set(observed_by_id))
    extra = sorted(set(observed_by_id) - set(expected_by_id))
    mismatched = {
        identity: {
            "expected": expected_by_id[identity],
            "observed": observed_by_id[identity],
        }
        for identity in sorted(set(expected_by_id) & set(observed_by_id))
        if expected_by_id[identity] != observed_by_id[identity]
    }
    raise AuthorityError(
        f"{label} graph differs from semantic authority: missing={missing}, "
        f"extra={extra}, mismatched={json.dumps(mismatched, sort_keys=True)}"
    )


def concrete_payload(root: pathlib.Path, manifest: dict[str, Any]) -> dict[str, Any]:
    def resolved_state(pin: dict[str, Any]) -> dict[str, Any]:
        state = {"revision": pin["revision"]}
        if pin["version"] is not None:
            state["version"] = pin["version"]
        return state

    return {
        "originHash": compute_origin_hash(root, manifest),
        "pins": [
            {
                "identity": pin["identity"],
                "kind": pin["kind"],
                "location": pin["location"],
                "state": resolved_state(pin),
            }
            for pin in manifest["pins"]
        ],
        "version": manifest["resolvedFileSchemaVersion"],
    }


def materialize_concrete(
    root: pathlib.Path, manifest: dict[str, Any], output: pathlib.Path
) -> dict[str, Any]:
    expected = json.dumps(concrete_payload(root, manifest), indent=2) + "\n"
    if output.exists():
        observed = output.read_text(encoding="utf-8")
        if observed != expected:
            raise AuthorityError(
                f"refusing to overwrite non-deterministic concrete resolved file: {output}"
            )
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="\n",
            dir=output.parent,
            prefix=".Package.resolved.",
            delete=False,
        ) as temporary:
            temporary.write(expected)
            temporary_path = pathlib.Path(temporary.name)
        try:
            os.replace(temporary_path, output)
        finally:
            temporary_path.unlink(missing_ok=True)
    return validate_concrete(root, manifest, output, require_origin_hash=True)


def validate_concrete(
    root: pathlib.Path,
    manifest: dict[str, Any],
    resolved_path: pathlib.Path,
    *,
    require_origin_hash: bool,
) -> dict[str, Any]:
    payload = load_json(resolved_path)
    _require_exact_keys(payload, {"originHash", "pins", "version"}, "concrete resolved file")
    if payload["version"] != manifest["resolvedFileSchemaVersion"]:
        raise AuthorityError(f"unsupported resolved-file schema version: {payload['version']!r}")
    origin_hash = payload["originHash"]
    if require_origin_hash and (
        not isinstance(origin_hash, str) or HEX64.fullmatch(origin_hash) is None
    ):
        raise AuthorityError("concrete resolved file lacks a valid originHash")
    expected_origin_hash = compute_origin_hash(root, manifest)
    if origin_hash != expected_origin_hash:
        raise AuthorityError(
            f"concrete originHash is bound to a different build root: "
            f"expected {expected_origin_hash}, observed {origin_hash}"
        )
    observed = semantic_pins_from_resolved(payload, "concrete")
    expected = semantic_pins_from_manifest(manifest)
    compare_semantic_pins(observed, expected, "concrete")
    semantic = {
        "schema": SCHEMA,
        "resolvedFileSchemaVersion": payload["version"],
        "localPackages": manifest["localPackages"],
        "sourcePatches": manifest["sourcePatches"],
        "binaryArtifacts": manifest["binaryArtifacts"],
        "pins": observed,
    }
    data = resolved_path.read_bytes()
    return {
        "resolvedPath": str(resolved_path),
        "rawSHA256": sha256_bytes(data),
        "bytes": len(data),
        "originHash": origin_hash,
        "semanticSHA256": sha256_bytes(canonical_json(semantic)),
        "pinCount": len(observed),
        "pins": observed,
    }


def validate_scoped_resolved(
    manifest: dict[str, Any], resolved_path: pathlib.Path, scope: str
) -> dict[str, Any]:
    scopes = {
        "openclawkit": {
            "elevenlabskit",
            "grdb.swift",
            "swift-concurrency-extras",
            "swiftui-math",
            "textual",
        }
    }
    if scope not in scopes:
        raise AuthorityError(f"unsupported resolved graph scope: {scope!r}")
    payload = load_json(resolved_path)
    _require_exact_keys(payload, {"originHash", "pins", "version"}, f"{scope} resolved file")
    if payload["version"] != manifest["resolvedFileSchemaVersion"]:
        raise AuthorityError(f"unsupported resolved-file schema version: {payload['version']!r}")
    origin_hash = payload["originHash"]
    if not isinstance(origin_hash, str) or HEX64.fullmatch(origin_hash) is None:
        raise AuthorityError(f"{scope} resolved file lacks a valid originHash")
    observed = semantic_pins_from_resolved(payload, scope)
    expected = [
        pin
        for pin in semantic_pins_from_manifest(manifest)
        if pin["identity"] in scopes[scope]
    ]
    compare_semantic_pins(observed, expected, scope)
    semantic = {
        "schema": SCHEMA,
        "scope": scope,
        "sourcePatches": manifest["sourcePatches"],
        "pins": observed,
    }
    return {
        "status": "valid",
        "scope": scope,
        "resolvedPath": str(resolved_path),
        "rawSHA256": sha256_bytes(resolved_path.read_bytes()),
        "originHash": origin_hash,
        "semanticSHA256": sha256_bytes(canonical_json(semantic)),
        "pinCount": len(observed),
        "pins": observed,
    }


def validate_workspace_state(
    manifest: dict[str, Any], workspace_state_path: pathlib.Path
) -> dict[str, Any]:
    payload = load_json(workspace_state_path)
    if payload.get("version") != 7:
        raise AuthorityError(
            f"unsupported SwiftPM workspace-state schema: {payload.get('version')!r}"
        )
    root = payload.get("object")
    if not isinstance(root, dict):
        raise AuthorityError("workspace-state object is missing")
    dependencies = root.get("dependencies")
    if not isinstance(dependencies, list):
        raise AuthorityError("workspace-state dependencies are missing")
    observed = []
    for index, dependency in enumerate(dependencies):
        if not isinstance(dependency, dict):
            raise AuthorityError(f"workspace dependency {index} is invalid")
        package_ref = dependency.get("packageRef")
        state_wrapper = dependency.get("state")
        if not isinstance(package_ref, dict) or not isinstance(state_wrapper, dict):
            raise AuthorityError(f"workspace dependency {index} lacks packageRef or state")
        checkout_state = state_wrapper.get("checkoutState")
        if state_wrapper.get("name") != "sourceControlCheckout" or not isinstance(
            checkout_state, dict
        ):
            raise AuthorityError(f"workspace dependency {index} is not source-control checkout")
        observed.append(
            {
                "identity": package_ref.get("identity"),
                "kind": package_ref.get("kind"),
                "location": package_ref.get("location"),
                "canonicalLocation": canonical_location(package_ref.get("location")),
                "version": checkout_state.get("version"),
                "revision": checkout_state.get("revision"),
                "branch": checkout_state.get("branch"),
                "checksum": checkout_state.get("checksum"),
            }
        )
    observed.sort(key=lambda pin: pin["identity"] or "")
    expected = semantic_pins_from_manifest(manifest)
    if observed != expected:
        raise AuthorityError("workspace-state dependency graph differs from semantic authority")
    artifacts = root.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 1:
        raise AuthorityError("workspace-state must contain exactly one binary artifact")
    observed_artifact = artifacts[0]
    if not isinstance(observed_artifact, dict):
        raise AuthorityError("workspace-state binary artifact is invalid")
    package_ref = observed_artifact.get("packageRef") or {}
    source = observed_artifact.get("source") or {}
    normalized_artifact = {
        "packageIdentity": package_ref.get("identity"),
        "targetName": observed_artifact.get("targetName"),
        "url": source.get("url"),
        "checksumAlgorithm": "sha256",
        "checksum": source.get("checksum"),
    }
    if source.get("type") != "remote" or normalized_artifact != manifest["binaryArtifacts"][0]:
        raise AuthorityError("workspace-state WebRTC artifact URL or checksum differs")
    return {
        "workspaceStatePath": str(workspace_state_path),
        "workspaceStateSHA256": sha256_bytes(workspace_state_path.read_bytes()),
        "schemaVersion": payload["version"],
        "pinCount": len(observed),
        "semanticSHA256": sha256_bytes(
            canonical_json(
                {
                    "pins": observed,
                    "binaryArtifacts": [normalized_artifact],
                }
            )
        ),
        "binaryArtifacts": [normalized_artifact],
    }


def validate_source_patch_checkout(
    root: pathlib.Path,
    manifest: dict[str, Any],
    workspace_state_path: pathlib.Path,
    source_packages_root: pathlib.Path,
) -> dict[str, Any]:
    """Prove that SwiftPM consumed the exact governed ElevenLabsKit patch tree."""
    payload = load_json(workspace_state_path)
    workspace_object = payload.get("object")
    if not isinstance(workspace_object, dict):
        raise AuthorityError("workspace-state object is missing for source-patch proof")
    dependencies = workspace_object.get("dependencies")
    if not isinstance(dependencies, list):
        raise AuthorityError("workspace-state dependencies are missing for source-patch proof")
    matches = [
        dependency
        for dependency in dependencies
        if isinstance(dependency, dict)
        and isinstance(dependency.get("packageRef"), dict)
        and dependency["packageRef"].get("identity") == "elevenlabskit"
    ]
    if len(matches) != 1:
        raise AuthorityError("workspace state must name exactly one ElevenLabsKit checkout")
    subpath = matches[0].get("subpath")
    if not isinstance(subpath, str):
        raise AuthorityError("ElevenLabsKit workspace-state checkout subpath is missing")
    relative = pathlib.PurePosixPath(subpath)
    if relative.is_absolute() or len(relative.parts) != 1 or relative.name in {"", ".", ".."}:
        raise AuthorityError("ElevenLabsKit checkout subpath is unsafe")
    checkouts_root = (source_packages_root.resolve() / "checkouts").resolve()
    checkout = (checkouts_root / relative.name).resolve()
    try:
        checkout.relative_to(checkouts_root)
    except ValueError as error:
        raise AuthorityError("ElevenLabsKit checkout escapes cloned-source custody") from error
    if not checkout.is_dir():
        raise AuthorityError(f"ElevenLabsKit checkout is missing: {checkout}")

    provenance = load_json(repo_path(root, manifest["sourcePatches"][0]["path"]))
    original = provenance["original"]
    patch = provenance["patch"]

    def git_text(*arguments: str) -> str:
        try:
            completed = subprocess.run(
                ["git", *arguments],
                cwd=checkout,
                capture_output=True,
                check=True,
                text=True,
            )
        except subprocess.CalledProcessError as error:
            raise AuthorityError(
                "unable to inspect governed ElevenLabsKit checkout: "
                + " ".join(arguments)
            ) from error
        return completed.stdout

    def git_bytes(*arguments: str) -> bytes:
        try:
            completed = subprocess.run(
                ["git", *arguments],
                cwd=checkout,
                capture_output=True,
                check=True,
            )
        except subprocess.CalledProcessError as error:
            raise AuthorityError(
                "unable to inspect governed ElevenLabsKit checkout bytes: "
                + " ".join(arguments)
            ) from error
        return completed.stdout

    observed_head = git_text("rev-parse", "HEAD").strip()
    observed_tree = git_text("rev-parse", "HEAD^{tree}").strip()
    observed_parents = git_text("show", "-s", "--format=%P", "HEAD").strip().split()
    original_tree = git_text("rev-parse", f"{original['revision']}^{{tree}}").strip()
    status = git_text("status", "--porcelain=v2", "--untracked-files=all")
    changed_paths = git_text(
        "diff", "--name-only", original["revision"], patch["revision"]
    ).splitlines()
    original_manifest = git_bytes("show", f"{original['revision']}:Package.swift")
    patched_manifest = git_bytes("show", f"{patch['revision']}:Package.swift")
    binary_diff = git_bytes("diff", "--binary", original["revision"], patch["revision"])

    if observed_head != patch["revision"]:
        raise AuthorityError("ElevenLabsKit checkout HEAD differs from governed patch revision")
    if observed_tree != patch["tree"]:
        raise AuthorityError("ElevenLabsKit checkout tree differs from governed patch tree")
    if observed_parents != [original["revision"]]:
        raise AuthorityError("ElevenLabsKit patch must have the exact 0.1.1 commit as sole parent")
    if original_tree != original["tree"]:
        raise AuthorityError("ElevenLabsKit original commit tree differs from 0.1.1 provenance")
    if status:
        raise AuthorityError("ElevenLabsKit strict checkout is dirty")
    if changed_paths != patch["changedPaths"]:
        raise AuthorityError("ElevenLabsKit checkout changed paths differ from provenance")
    if original_manifest != patched_manifest:
        raise AuthorityError("ElevenLabsKit dependency Package.swift changed in patch")
    manifest_sha256 = sha256_bytes(original_manifest)
    if manifest_sha256 != "f45bc818aec405d5f4250cff4e95619c951041b12234a984bfb10e2bdf787431":
        raise AuthorityError("ElevenLabsKit dependency Package.swift hash differs from 0.1.1")
    binary_diff_sha256 = sha256_bytes(binary_diff)
    if binary_diff_sha256 != "cac0a890ee88be89b3b3956030c330453f4edbef03d9f3d81797b57be884ab5a":
        raise AuthorityError("ElevenLabsKit binary patch digest differs from reviewed delta")

    return {
        "schema": "aies.ios.package-source-patch-checkout.v1",
        "status": "verified",
        "packageIdentity": "elevenlabskit",
        "checkout": str(checkout),
        "workspaceStateSubpath": subpath,
        "head": observed_head,
        "tree": observed_tree,
        "soleParent": observed_parents[0],
        "originalTree": original_tree,
        "changedPaths": changed_paths,
        "dependencyManifestSHA256": manifest_sha256,
        "binaryDiffSHA256": binary_diff_sha256,
        "binaryDiffBytes": len(binary_diff),
        "statusPorcelainV2": status,
    }


def git_status(root: pathlib.Path) -> str:
    result = subprocess.run(
        ["git", "status", "--porcelain=v2", "--untracked-files=all"],
        cwd=root,
        capture_output=True,
        check=True,
        text=True,
    )
    return result.stdout


def write_report(report: dict[str, Any], output: str | None) -> None:
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if output:
        path = pathlib.Path(output)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(encoded, encoding="utf-8", newline="\n")
    print(encoded, end="")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo-root", required=True)
    result.add_argument("--manifest", default=DEFAULT_MANIFEST)
    subparsers = result.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate-authority")
    validate.add_argument("--output")
    materialize = subparsers.add_parser("materialize")
    materialize.add_argument("--output")
    concrete = subparsers.add_parser("validate-concrete")
    concrete.add_argument("--resolved", required=True)
    concrete.add_argument("--output")
    compare = subparsers.add_parser("compare")
    compare.add_argument("--left-root", required=True)
    compare.add_argument("--left-resolved", required=True)
    compare.add_argument("--right-root", required=True)
    compare.add_argument("--right-resolved", required=True)
    compare.add_argument("--output")
    workspace = subparsers.add_parser("validate-workspace-state")
    workspace.add_argument("--workspace-state", required=True)
    workspace.add_argument("--output")
    origin = subparsers.add_parser("origin-hash")
    origin.add_argument("--output")
    scoped = subparsers.add_parser("validate-scoped-resolved")
    scoped.add_argument("--scope", required=True, choices=["openclawkit"])
    scoped.add_argument("--resolved", required=True)
    scoped.add_argument("--output")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    root = pathlib.Path(args.repo_root).resolve()
    manifest_path = repo_path(root, args.manifest)
    try:
        manifest = validate_manifest(root, manifest_path)
        if args.command == "validate-authority":
            semantic = {
                "schema": manifest["schema"],
                "sourceDeclarations": manifest["sourceDeclarations"],
                "sourcePatches": manifest["sourcePatches"],
                "standaloneLocks": manifest["standaloneLocks"],
                "localPackages": manifest["localPackages"],
                "binaryArtifacts": manifest["binaryArtifacts"],
                "pins": semantic_pins_from_manifest(manifest),
            }
            report = {
                "status": "valid",
                "manifest": str(manifest_path),
                "manifestSHA256": sha256_bytes(manifest_path.read_bytes()),
                "semanticSHA256": sha256_bytes(canonical_json(semantic)),
                "pinCount": len(manifest["pins"]),
                "standaloneLockSHA256": manifest["standaloneLocks"][0]["sha256"],
                "sourceStatusPorcelainV2": git_status(root),
            }
            write_report(report, args.output)
        elif args.command == "materialize":
            output = (
                pathlib.Path(args.output).resolve()
                if args.output
                else repo_path(root, manifest["project"]["concreteResolvedPath"])
            )
            report = materialize_concrete(root, manifest, output)
            write_report(report, None)
        elif args.command == "validate-concrete":
            report = validate_concrete(
                root,
                manifest,
                pathlib.Path(args.resolved).resolve(),
                require_origin_hash=True,
            )
            write_report(report, args.output)
        elif args.command == "compare":
            left_root = pathlib.Path(args.left_root).resolve()
            right_root = pathlib.Path(args.right_root).resolve()
            left_manifest = validate_manifest(left_root, repo_path(left_root, args.manifest))
            right_manifest = validate_manifest(right_root, repo_path(right_root, args.manifest))
            left = validate_concrete(
                left_root,
                left_manifest,
                pathlib.Path(args.left_resolved).resolve(),
                require_origin_hash=True,
            )
            right = validate_concrete(
                right_root,
                right_manifest,
                pathlib.Path(args.right_resolved).resolve(),
                require_origin_hash=True,
            )
            if left["semanticSHA256"] != right["semanticSHA256"]:
                raise AuthorityError("concrete graphs are not semantically identical")
            report = {
                "status": "semantically-identical",
                "semanticSHA256": left["semanticSHA256"],
                "left": left,
                "right": right,
                "originHashesDiffer": left["originHash"] != right["originHash"],
                "rawHashesDiffer": left["rawSHA256"] != right["rawSHA256"],
            }
            write_report(report, args.output)
        elif args.command == "validate-workspace-state":
            report = validate_workspace_state(
                manifest, pathlib.Path(args.workspace_state).resolve()
            )
            write_report(report, args.output)
        elif args.command == "origin-hash":
            write_report(
                {
                    "contract": manifest["originHash"]["contract"],
                    "originHash": compute_origin_hash(root, manifest),
                    "repoRoot": str(root),
                },
                args.output,
            )
        elif args.command == "validate-scoped-resolved":
            report = validate_scoped_resolved(
                manifest, pathlib.Path(args.resolved).resolve(), args.scope
            )
            write_report(report, args.output)
        else:  # pragma: no cover - argparse enforces the command set.
            raise AuthorityError(f"unsupported command: {args.command}")
    except (AuthorityError, OSError, subprocess.CalledProcessError) as error:
        print(f"PACKAGE_AUTHORITY_ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
