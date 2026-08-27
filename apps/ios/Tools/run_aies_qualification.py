#!/usr/bin/env python3
"""Run and seal credential-free AIES XCTest qualification evidence.

This tool deliberately owns only already-built simulator test products. It can
enumerate tests and launch fresh ``xcodebuild test-without-building`` processes;
it cannot build, archive, sign, export, upload, or resolve dependencies.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import json
import os
import pathlib
import signal
import shlex
import subprocess
import sys
from typing import Any, Iterable, Sequence


ENUMERATION_SCHEMA = "aies.ios.test-enumeration.v1"
PRODUCTS_SCHEMA = "aies.ios.test-products.v1"
RUN_SCHEMA = "aies.ios.test-without-building-run.v1"
MATRIX_SCHEMA = "aies.ios.test-without-building-matrix.v1"
SIMULATOR_RESET_SCHEMA = "aies.ios.simulator-reset.v1"
SIMULATOR_RESET_TIMEOUT_SECONDS = 180

SAFE_FLAG_ARGUMENTS = {
    "-disableAutomaticPackageResolution",
    "-disablePackageRepositoryCache",
    "-onlyUsePackageVersionsFromResolvedFile",
    "-skipPackageUpdates",
}
SAFE_VALUE_ARGUMENTS = {
    "-clonedSourcePackagesDirPath",
    "-packageCachePath",
}


class QualificationError(RuntimeError):
    """A fail-closed qualification harness error."""


class QualificationInfrastructureError(QualificationError):
    """An evidenced XCTest/CoreSimulator failure before a product test ran."""

    def __init__(self, classification: str, message: str) -> None:
        super().__init__(message)
        self.classification = classification


@dataclasses.dataclass(frozen=True)
class ProcessOutcome:
    arguments: list[str]
    pid: int
    status: int
    started_at: str
    finished_at: str
    timed_out: bool


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def write_new_json(path: pathlib.Path, value: Any) -> None:
    if path.exists() or path.is_symlink():
        raise QualificationError(f"refusing to overwrite evidence: {path}")
    write_json(path, value)


def read_json(path: pathlib.Path, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise QualificationError(f"{label} is missing or invalid JSON: {path}") from error


def require_empty_output(path: pathlib.Path, label: str) -> pathlib.Path:
    path = path.resolve()
    if path.exists():
        if not path.is_dir():
            raise QualificationError(f"{label} is not a directory: {path}")
        if any(path.iterdir()):
            raise QualificationError(f"{label} must be empty: {path}")
    else:
        path.mkdir(parents=True)
    return path


def require_xctestrun(path: pathlib.Path) -> pathlib.Path:
    if path.is_symlink():
        raise QualificationError(f"xctestrun must not be a symlink: {path}")
    path = path.resolve()
    if path.suffix != ".xctestrun" or not path.is_file():
        raise QualificationError(f"expected one regular .xctestrun file: {path}")
    return path


def paths_overlap(first: pathlib.Path, second: pathlib.Path) -> bool:
    first = first.resolve()
    second = second.resolve()
    try:
        first.relative_to(second)
        return True
    except ValueError:
        pass
    try:
        second.relative_to(first)
        return True
    except ValueError:
        return False


def require_separate_output(output: pathlib.Path, products_root: pathlib.Path) -> None:
    if paths_overlap(output, products_root):
        raise QualificationError(
            f"evidence output and test-products root must not overlap: {output} / {products_root}"
        )


def locate_xctestrun(products_root: pathlib.Path) -> pathlib.Path:
    products_root = products_root.resolve()
    if not products_root.is_dir():
        raise QualificationError(f"test-products directory is missing: {products_root}")
    candidates = sorted(
        path.resolve()
        for path in products_root.rglob("*.xctestrun")
        if path.is_file() and not path.is_symlink()
    )
    if len(candidates) != 1:
        rendered = ", ".join(str(path) for path in candidates) or "none"
        raise QualificationError(
            f"expected exactly one .xctestrun under {products_root}; "
            f"found {len(candidates)}: {rendered}"
        )
    return candidates[0]


def path_record(path: pathlib.Path, root: pathlib.Path) -> dict[str, Any]:
    relative = path.relative_to(root).as_posix()
    if path.is_symlink():
        target = os.readlink(path)
        return {
            "bytes": len(target.encode("utf-8")),
            "path": relative,
            "sha256": sha256_bytes(target.encode("utf-8")),
            "symlinkTarget": target,
            "type": "symlink",
        }
    if not path.is_file():
        raise QualificationError(f"unsupported test-product object: {path}")
    return {
        "bytes": path.stat().st_size,
        "path": relative,
        "sha256": sha256_file(path),
        "type": "file",
    }


def test_product_inventory(
    products_root: pathlib.Path, xctestrun: pathlib.Path | None = None
) -> dict[str, Any]:
    products_root = products_root.resolve()
    if not products_root.is_dir():
        raise QualificationError(f"test-products directory is missing: {products_root}")
    xctestrun = require_xctestrun(xctestrun or locate_xctestrun(products_root))
    try:
        xctestrun.relative_to(products_root)
    except ValueError as error:
        raise QualificationError("xctestrun must be inside the test-products root") from error

    paths = sorted(
        (path for path in products_root.rglob("*") if path.is_file() or path.is_symlink()),
        key=lambda item: item.relative_to(products_root).as_posix(),
    )
    if not paths:
        raise QualificationError("test-products directory contains no files")
    records = [path_record(path, products_root) for path in paths]
    combined = hashlib.sha256()
    for record in records:
        combined.update(record["type"].encode("ascii"))
        combined.update(b"\0")
        combined.update(record["path"].encode("utf-8"))
        combined.update(b"\0")
        combined.update(record["sha256"].encode("ascii"))
        combined.update(b"\0")
        combined.update(str(record["bytes"]).encode("ascii"))
        combined.update(b"\n")
    return {
        "schema": PRODUCTS_SCHEMA,
        "productsRoot": str(products_root),
        "xctestrun": xctestrun.relative_to(products_root).as_posix(),
        "xctestrunSHA256": sha256_file(xctestrun),
        "fileCount": len(records),
        "treeSHA256": combined.hexdigest(),
        "files": records,
    }


def stable_test_product_inventory(
    products_root: pathlib.Path, xctestrun: pathlib.Path | None = None
) -> dict[str, Any]:
    first = test_product_inventory(products_root, xctestrun)
    second = test_product_inventory(products_root, xctestrun)
    if first != second:
        raise QualificationError("test products changed while being inventoried")
    return first


def verify_products_manifest(
    manifest_path: pathlib.Path, xctestrun: pathlib.Path
) -> tuple[dict[str, Any], dict[str, Any]]:
    expected = read_json(manifest_path, "test-products manifest")
    if not isinstance(expected, dict) or expected.get("schema") != PRODUCTS_SCHEMA:
        raise QualificationError("test-products manifest has an unsupported schema")
    root_value = expected.get("productsRoot")
    if not isinstance(root_value, str):
        raise QualificationError("test-products manifest lacks productsRoot")
    products_root = pathlib.Path(root_value).resolve()
    observed = stable_test_product_inventory(products_root, xctestrun)
    if observed != expected:
        raise QualificationError("compiled test products differ from the saved manifest")
    return expected, observed


def read_extra_xcode_arguments(
    inline: Sequence[str], arguments_file: pathlib.Path | None
) -> list[str]:
    arguments = list(inline)
    if arguments_file is not None:
        try:
            lines = arguments_file.read_text(encoding="utf-8").splitlines()
        except OSError as error:
            raise QualificationError(
                f"cannot read Xcode arguments file: {arguments_file}"
            ) from error
        arguments.extend(line for line in lines if line)
    return validate_extra_xcode_arguments(arguments)


def validate_extra_xcode_arguments(arguments: Sequence[str]) -> list[str]:
    """Allow only strict, credential-free package-custody arguments."""
    validated: list[str] = []
    observed: set[str] = set()
    path_values: dict[str, pathlib.Path] = {}
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if not argument or "\0" in argument or "\n" in argument or "\r" in argument:
            raise QualificationError("Xcode arguments must be non-empty single-line values")
        if argument in observed:
            raise QualificationError(f"duplicate Xcode argument is prohibited: {argument}")
        if argument in SAFE_FLAG_ARGUMENTS:
            observed.add(argument)
            validated.append(argument)
            index += 1
            continue
        if argument in SAFE_VALUE_ARGUMENTS:
            if index + 1 >= len(arguments):
                raise QualificationError(f"Xcode argument requires one value: {argument}")
            value = arguments[index + 1]
            if (
                not value
                or value.startswith("-")
                or "\0" in value
                or "\n" in value
                or "\r" in value
                or not pathlib.Path(value).is_absolute()
            ):
                raise QualificationError(f"invalid value for Xcode argument: {argument}")
            observed.add(argument)
            path_values[argument] = pathlib.Path(value).resolve()
            validated.extend([argument, value])
            index += 2
            continue
        raise QualificationError(
            "qualification runner accepts only strict package-custody Xcode arguments; "
            f"rejected: {argument}"
        )
    required = SAFE_FLAG_ARGUMENTS | SAFE_VALUE_ARGUMENTS
    if observed != required:
        missing = ", ".join(sorted(required - observed))
        raise QualificationError(f"strict package-custody arguments are incomplete: {missing}")
    if paths_overlap(
        path_values["-clonedSourcePackagesDirPath"],
        path_values["-packageCachePath"],
    ):
        raise QualificationError("cloned package sources and package cache must not overlap")
    return validated


def validate_only_testing(value: str) -> str:
    if not value or value.startswith("-") or any(char in value for char in "\0\r\n"):
        raise QualificationError(f"invalid only-testing filter: {value!r}")
    parts = [part for part in value.strip("/").split("/") if part]
    if len(parts) not in {2, 3}:
        raise QualificationError(
            "only-testing must identify Module/Suite or Module/Suite/Test"
        )
    return "/".join(parts)


def canonical_identifier(value: str) -> str:
    parts = [part.removesuffix("()") for part in value.strip().strip("/").split("/")]
    parts = [part for part in parts if part]
    return "/".join(parts[-2:]) if len(parts) in {2, 3} else ""


def identifier_matches_filter(identifier: str, only_testing: str) -> bool:
    identifier_parts = [
        part.removesuffix("()")
        for part in identifier.strip().strip("/").split("/")
        if part
    ]
    filter_parts = [
        part.removesuffix("()")
        for part in only_testing.strip("/").split("/")
        if part
    ]
    if len(identifier_parts) != 3 or len(filter_parts) not in {2, 3}:
        return False
    module = filter_parts[0]
    suite = filter_parts[1]
    test_name = filter_parts[2] if len(filter_parts) == 3 else None
    for index in range(len(identifier_parts) - 1):
        if identifier_parts[index : index + 2] != [module, suite]:
            continue
        if index + 2 >= len(identifier_parts):
            return False
        return test_name is None or identifier_parts[index + 2] == test_name
    return False


def collect_enumerated_test_records(
    payload: Any, only_testing: str
) -> list[dict[str, str]]:
    if not isinstance(payload, dict):
        raise QualificationError("Xcode enumeration payload must be an object")
    errors = payload.get("errors")
    values = payload.get("values")
    if errors != [] or not isinstance(values, list) or not values:
        raise QualificationError("Xcode enumeration contains errors or no configurations")
    candidates: list[dict[str, str]] = []
    for configuration in values:
        if not isinstance(configuration, dict):
            raise QualificationError("Xcode enumeration configuration must be an object")
        enabled = configuration.get("enabledTests")
        if not isinstance(enabled, list):
            raise QualificationError("Xcode enumeration lacks enabledTests")
        for test in enabled:
            if not isinstance(test, dict) or not isinstance(test.get("identifier"), str):
                raise QualificationError("enabled Xcode test lacks a string identifier")
            identifier = test["identifier"]
            if not identifier_matches_filter(identifier, only_testing):
                continue
            canonical = canonical_identifier(identifier)
            if not canonical:
                raise QualificationError(f"enabled test identifier is invalid: {identifier}")
            candidates.append(
                {"identifier": canonical, "rawIdentifier": identifier}
            )
    canonical = [candidate["identifier"] for candidate in candidates]
    raw = [candidate["rawIdentifier"] for candidate in candidates]
    if len(canonical) != len(set(canonical)) or len(raw) != len(set(raw)):
        raise QualificationError("Xcode enumeration contains duplicate enabled tests")
    return sorted(candidates, key=lambda candidate: candidate["identifier"])


def collect_enumerated_identifiers(payload: Any, only_testing: str) -> list[str]:
    return [
        record["identifier"]
        for record in collect_enumerated_test_records(payload, only_testing)
    ]


def narrow_enumeration(
    *,
    source_path: pathlib.Path,
    xctestrun: pathlib.Path,
    destination: str,
    source_only_testing: str,
    source_expected_test_count: int,
    only_testing: str,
    output: pathlib.Path,
) -> dict[str, Any]:
    """Derive one exact leaf from an already sealed suite enumeration.

    Xcode 26.2 can report a selected Swift Testing leaf in ``disabledTests``
    when ``-enumerate-tests`` is combined with a normalized leaf
    ``-only-testing`` filter. Suite enumeration is stable and retains Xcode's
    exact raw ``testName()`` selector, so qualification narrows that sealed
    inventory, executes the raw selector, and validates every actual XCResult
    against the resulting single canonical identifier.
    """
    xctestrun = require_xctestrun(xctestrun)
    source_only_testing = validate_only_testing(source_only_testing)
    only_testing = validate_only_testing(only_testing)
    source_parts = source_only_testing.split("/")
    target_parts = only_testing.split("/")
    if len(source_parts) != 2:
        raise QualificationError("source enumeration must identify Module/Suite")
    if len(target_parts) != 3:
        raise QualificationError("narrowed enumeration must identify one exact test")
    if target_parts[:2] != source_parts:
        raise QualificationError(
            "narrowed test must belong to the enumerated module and suite"
        )
    if source_expected_test_count < 1:
        raise QualificationError("source expected test count must be positive")
    source = load_enumeration(
        source_path,
        xctestrun,
        destination,
        source_only_testing,
        source_expected_test_count,
    )
    target_identifier = "/".join(target_parts[-2:])
    raw_identifiers = source.get("rawTestIdentifiers")
    if (
        not isinstance(raw_identifiers, list)
        or any(not isinstance(value, str) for value in raw_identifiers)
        or len(raw_identifiers) != source_expected_test_count
        or len(set(raw_identifiers)) != len(raw_identifiers)
    ):
        raise QualificationError("source enumeration lacks exact raw test identifiers")
    source_identifiers = source["testIdentifiers"]
    raw_canonical: list[str] = []
    for raw_identifier in raw_identifiers:
        canonical = canonical_identifier(raw_identifier)
        if (
            not raw_identifier.endswith("()")
            or not canonical
            or not identifier_matches_filter(raw_identifier, source_only_testing)
        ):
            raise QualificationError(
                "source raw test identifier does not belong to the enumerated suite"
            )
        raw_canonical.append(canonical)
    if sorted(raw_canonical) != sorted(source_identifiers):
        raise QualificationError(
            "source raw and canonical test inventories differ"
        )
    for key in ("productsManifestSHA256", "productsTreeSHA256"):
        value = source.get(key)
        if (
            not isinstance(value, str)
            or len(value) != 64
            or any(character not in "0123456789abcdef" for character in value)
        ):
            raise QualificationError(f"source enumeration has invalid {key}")
    raw_matches = [
        identifier
        for identifier in raw_identifiers
        if canonical_identifier(identifier) == target_identifier
        and identifier_matches_filter(identifier, only_testing)
    ]
    if len(raw_matches) != 1:
        raise QualificationError(
            "exact narrowed test is absent or ambiguous in the suite enumeration"
        )
    raw_target = raw_matches[0]
    manifest = {
        "schema": ENUMERATION_SCHEMA,
        "destination": destination,
        "expectedTestCount": 1,
        "onlyTesting": raw_target,
        "productsManifestSHA256": source["productsManifestSHA256"],
        "productsTreeSHA256": source["productsTreeSHA256"],
        "rawTestIdentifiers": [raw_target],
        "requestedOnlyTesting": only_testing,
        "sourceEnumerationSHA256": sha256_file(source_path),
        "sourceExpectedTestCount": source_expected_test_count,
        "sourceOnlyTesting": source_only_testing,
        "testIdentifiers": [target_identifier],
        "xctestrun": str(xctestrun),
        "xctestrunSHA256": source.get("xctestrunSHA256"),
    }
    write_new_json(output, manifest)
    return manifest


def collect_xcresult_cases(payload: Any) -> list[dict[str, str]]:
    cases: list[dict[str, str]] = []

    def walk(value: Any, inside_system_failures: bool = False) -> None:
        if isinstance(value, dict):
            is_system_failures = inside_system_failures or (
                value.get("nodeType") == "Test Suite"
                and value.get("name") == "System Failures"
            )
            if value.get("nodeType") == "Test Case":
                if is_system_failures:
                    return
                identifier = value.get("nodeIdentifier")
                result = value.get("result")
                if not isinstance(identifier, str) or not isinstance(result, str):
                    raise QualificationError(
                        "XCResult Test Case lacks a string identifier or result"
                    )
                identifier_parts = [
                    part.removesuffix("()")
                    for part in identifier.strip().strip("/").split("/")
                    if part
                ]
                if len(identifier_parts) != 2:
                    raise QualificationError(
                        f"XCResult Test Case has invalid identifier: {identifier!r}"
                    )
                canonical = "/".join(identifier_parts)
                cases.append(
                    {
                        "identifier": canonical,
                        "rawIdentifier": identifier,
                        "result": result,
                    }
                )
            for child in value.values():
                walk(child, is_system_failures)
        elif isinstance(value, list):
            for child in value:
                walk(child, inside_system_failures)

    walk(payload)
    return cases


def collect_xcresult_system_failures(payload: Any) -> list[dict[str, Any]]:
    failures: list[dict[str, Any]] = []

    def failure_messages(value: Any) -> list[str]:
        messages: list[str] = []
        if isinstance(value, dict):
            if value.get("nodeType") == "Failure Message" and isinstance(
                value.get("name"), str
            ):
                messages.append(value["name"])
            for child in value.values():
                messages.extend(failure_messages(child))
        elif isinstance(value, list):
            for child in value:
                messages.extend(failure_messages(child))
        return messages

    def walk(value: Any, inside_system_failures: bool = False) -> None:
        if isinstance(value, dict):
            is_system_failures = inside_system_failures or (
                value.get("nodeType") == "Test Suite"
                and value.get("name") == "System Failures"
            )
            if value.get("nodeType") == "Test Case" and is_system_failures:
                failures.append(
                    {
                        "identifier": value.get("nodeIdentifier"),
                        "messages": failure_messages(value),
                        "result": value.get("result"),
                    }
                )
                return
            for child in value.values():
                walk(child, is_system_failures)
        elif isinstance(value, list):
            for child in value:
                walk(child, inside_system_failures)

    walk(payload)
    return failures


def summary_integer(summary: dict[str, Any], key: str) -> int | None:
    value = summary.get(key)
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    return None


def verify_passing_xcresult(
    summary: Any,
    tests: Any,
    expected_identifiers: Sequence[str],
    expected_test_count: int,
    destination: str,
) -> dict[str, Any]:
    if not isinstance(summary, dict):
        raise QualificationError("XCResult summary payload must be an object")
    expected = list(expected_identifiers)
    if len(expected) != expected_test_count or len(set(expected)) != len(expected):
        raise QualificationError(
            "saved enumeration does not contain the exact expected unique test count"
        )
    observed_cases = collect_xcresult_cases(tests)
    system_failures = collect_xcresult_system_failures(tests)
    system_failure_details = ""
    if system_failures:
        rendered = []
        for failure in system_failures:
            identifier = failure.get("identifier") or "unnamed XCTest system failure"
            messages = failure.get("messages") or []
            detail = "; ".join(str(message) for message in messages)
            rendered.append(f"{identifier}: {detail}" if detail else str(identifier))
        summary_failures = summary.get("testFailures")
        if isinstance(summary_failures, list):
            for failure in summary_failures:
                if isinstance(failure, dict) and isinstance(
                    failure.get("failureText"), str
                ):
                    text = failure["failureText"]
                    if not any(text in value for value in rendered):
                        rendered.append(f"XCResult summary: {text}")
        system_failure_details = " | ".join(rendered)
        classification = (
            "SIMULATOR_APP_LIFECYCLE_BUSY"
            if "installing or uninstalling" in system_failure_details
            else "XCTEST_INFRASTRUCTURE_FAILURE"
        )
        if not observed_cases:
            raise QualificationInfrastructureError(
                classification,
                "XCResult infrastructure/system failure before the expected test ran: "
                + system_failure_details,
            )
    observed_identifiers = [case["identifier"] for case in observed_cases]
    errors: list[str] = []
    if system_failure_details:
        errors.append(
            "XCResult contains a system failure in addition to executed tests: "
            + system_failure_details
        )
    if len(set(observed_identifiers)) != len(observed_identifiers):
        errors.append("XCResult contains duplicate canonical Test Case identifiers")
    if set(observed_identifiers) != set(expected):
        errors.append("XCResult Test Case identifiers differ from saved enumeration")
    nonpassing = [case for case in observed_cases if case["result"] != "Passed"]
    if nonpassing:
        errors.append("XCResult contains a non-passing Test Case")
    expected_summary = {
        "totalTestCount": expected_test_count,
        "passedTests": expected_test_count,
        "failedTests": 0,
        "skippedTests": 0,
    }
    observed_summary = {
        key: summary_integer(summary, key) for key in expected_summary
    }
    if observed_summary != expected_summary:
        errors.append("XCResult summary does not prove the exact passing test count")
    if str(summary.get("result", "")).lower() != "passed":
        errors.append("XCResult summary result is not passed")
    if summary_integer(summary, "expectedFailures") != 0:
        errors.append("XCResult summary contains expected failures")
    if summary.get("testFailures") != []:
        errors.append("XCResult summary testFailures is not empty")
    configurations = summary.get("devicesAndConfigurations")
    requested_destination = destination_fields(destination)
    if not isinstance(configurations, list) or len(configurations) != 1:
        errors.append("XCResult must contain exactly one device/configuration result")
    else:
        configuration = configurations[0]
        device = configuration.get("device") if isinstance(configuration, dict) else None
        expected_configuration = {
            "expectedFailures": 0,
            "failedTests": 0,
            "passedTests": expected_test_count,
            "skippedTests": 0,
        }
        if not isinstance(configuration, dict) or any(
            configuration.get(key) != value
            for key, value in expected_configuration.items()
        ):
            errors.append("XCResult device/configuration counts are not exact")
        if not isinstance(device, dict):
            errors.append("XCResult device/configuration lacks a device")
        else:
            if device.get("platform") != requested_destination.get("platform"):
                errors.append("XCResult platform differs from the requested destination")
            expected_device_id = requested_destination.get("id")
            if expected_device_id and device.get("deviceId") != expected_device_id:
                errors.append("XCResult device ID differs from the requested destination")
    report = {
        "errors": errors,
        "expectedIdentifiers": sorted(expected),
        "expectedTestCount": expected_test_count,
        "observedIdentifiers": sorted(observed_identifiers),
        "observedSummary": observed_summary,
        "result": summary.get("result"),
        "destination": destination,
        "valid": not errors,
    }
    if errors:
        raise QualificationError("; ".join(errors))
    return report


def command_record(arguments: Sequence[str]) -> dict[str, Any]:
    return {"arguments": list(arguments), "shell": False, "rendered": shlex.join(arguments)}


def execute_logged(
    arguments: list[str],
    output: pathlib.Path,
    cwd: pathlib.Path | None = None,
    *,
    timeout_seconds: int,
) -> ProcessOutcome:
    output.mkdir(parents=True, exist_ok=False)
    write_json(output / "command.json", command_record(arguments))
    started_at = utc_now()
    with (output / "xcodebuild.log").open("wb") as log:
        try:
            process = subprocess.Popen(
                arguments,
                cwd=cwd,
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except OSError as error:
            write_json(
                output / "process-status.json",
                {"error": str(error), "startedAt": started_at, "status": "launch_failed"},
            )
            raise QualificationError(f"could not launch {arguments[0]}: {error}") from error
        write_json(
            output / "process-launch.json",
            {"pid": process.pid, "startedAt": started_at},
        )
        timed_out = False
        try:
            status = process.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except (AttributeError, OSError):
                process.terminate()
            try:
                status = process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except (AttributeError, OSError):
                    process.kill()
                status = process.wait(timeout=10)
    finished_at = utc_now()
    outcome = ProcessOutcome(
        arguments, process.pid, status, started_at, finished_at, timed_out
    )
    write_json(
        output / "process-status.json",
        {
            "finishedAt": finished_at,
            "pid": process.pid,
            "startedAt": started_at,
            "status": status,
            "timedOut": timed_out,
            "timeoutSeconds": timeout_seconds,
        },
    )
    (output / "xcodebuild.exit-status").write_text(
        f"{status}\n", encoding="utf-8", newline="\n"
    )
    return outcome


def capture_command(
    arguments: list[str], output_prefix: pathlib.Path, timeout_seconds: int
) -> str:
    write_json(
        output_prefix.with_suffix(".command.json"), command_record(arguments)
    )
    try:
        result = subprocess.run(
            arguments,
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as error:
        output_prefix.with_suffix(".exit-status").write_text(
            "timed_out\n", encoding="utf-8", newline="\n"
        )
        raise QualificationError(
            f"command exceeded {timeout_seconds}s: {shlex.join(arguments)}"
        ) from error
    except OSError as error:
        raise QualificationError(f"could not launch {arguments[0]}: {error}") from error
    output_prefix.with_suffix(".stdout").write_text(
        result.stdout, encoding="utf-8", newline="\n"
    )
    output_prefix.with_suffix(".stderr").write_text(
        result.stderr, encoding="utf-8", newline="\n"
    )
    output_prefix.with_suffix(".exit-status").write_text(
        f"{result.returncode}\n", encoding="utf-8", newline="\n"
    )
    if result.returncode != 0:
        raise QualificationError(
            f"command failed with status {result.returncode}: {shlex.join(arguments)}"
        )
    return result.stdout


def destination_fields(destination: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for field in destination.split(","):
        if "=" not in field:
            continue
        key, value = (part.strip() for part in field.split("=", 1))
        if not key or not value or key in fields:
            raise QualificationError(f"invalid or duplicate destination field: {field!r}")
        fields[key] = value
    return fields


def simulator_state(payload: Any, udid: str) -> str:
    if not isinstance(payload, dict) or not isinstance(payload.get("devices"), dict):
        raise QualificationError("simctl device inventory has an unsupported shape")
    matches = [
        device
        for devices in payload["devices"].values()
        if isinstance(devices, list)
        for device in devices
        if isinstance(device, dict) and device.get("udid") == udid
    ]
    if len(matches) != 1 or not isinstance(matches[0].get("state"), str):
        raise QualificationError(
            f"simctl inventory does not contain exactly one state for {udid}"
        )
    return matches[0]["state"]


def reset_simulator(
    *,
    xcrun: str,
    destination: str,
    output: pathlib.Path,
    timeout_seconds: int = SIMULATOR_RESET_TIMEOUT_SECONDS,
) -> dict[str, Any]:
    """Reboot the selected simulator and wait for CoreSimulator boot completion.

    Fresh xcodebuild processes can otherwise overlap SpringBoard's asynchronous
    app install teardown. A completed shutdown/boot boundary clears that
    infrastructure state without retrying or changing any product assertion.
    """

    fields = destination_fields(destination)
    if fields.get("platform") != "iOS Simulator" or not fields.get("id"):
        raise QualificationError(
            "simulator reset requires an exact iOS Simulator destination ID"
        )
    if timeout_seconds < 1:
        raise QualificationError("simulator reset timeout must be positive")
    udid = fields["id"]
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    started_at = utc_now()

    def read_state(label: str) -> str:
        raw = capture_command(
            [xcrun, "simctl", "list", "-j", "devices"],
            output / label,
            timeout_seconds,
        )
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as error:
            raise QualificationError("simctl returned invalid device JSON") from error
        return simulator_state(payload, udid)

    try:
        state_before = read_state("list-before")
        if state_before == "Booted":
            capture_command(
                [xcrun, "simctl", "shutdown", udid],
                output / "shutdown",
                timeout_seconds,
            )
        elif state_before != "Shutdown":
            raise QualificationError(
                f"simulator {udid} is in unsupported state {state_before!r}"
            )
        state_after_shutdown = read_state("list-after-shutdown")
        if state_after_shutdown != "Shutdown":
            raise QualificationError(
                f"simulator {udid} did not reach Shutdown: {state_after_shutdown!r}"
            )
        capture_command(
            [xcrun, "simctl", "boot", udid],
            output / "boot",
            timeout_seconds,
        )
        capture_command(
            [xcrun, "simctl", "bootstatus", udid, "-b"],
            output / "bootstatus",
            timeout_seconds,
        )
        state_after_boot = read_state("list-after-boot")
        if state_after_boot != "Booted":
            raise QualificationError(
                f"simulator {udid} did not reach Booted: {state_after_boot!r}"
            )
        report = {
            "schema": SIMULATOR_RESET_SCHEMA,
            "destination": destination,
            "finishedAt": utc_now(),
            "startedAt": started_at,
            "stateAfterBoot": state_after_boot,
            "stateAfterShutdown": state_after_shutdown,
            "stateBefore": state_before,
            "status": "passed",
            "timeoutSeconds": timeout_seconds,
            "udid": udid,
        }
        write_json(output / "simulator-reset.json", report)
        return report
    except Exception as error:
        write_json(
            output / "simulator-reset-status.json",
            {
                "error": str(error),
                "finishedAt": utc_now(),
                "startedAt": started_at,
                "status": "failed",
                "type": type(error).__name__,
                "udid": udid,
            },
        )
        if isinstance(error, QualificationError):
            raise
        raise QualificationError(f"simulator reset failed: {error}") from error


def extract_xcresult(
    xcrun: str,
    result_bundle: pathlib.Path,
    output: pathlib.Path,
    timeout_seconds: int,
) -> tuple[Any, Any]:
    if not result_bundle.is_dir():
        raise QualificationError(f"XCResult bundle is missing: {result_bundle}")
    summary_text = capture_command(
        [
            xcrun,
            "xcresulttool",
            "get",
            "test-results",
            "summary",
            "--path",
            str(result_bundle),
        ],
        output / "xcresult-summary",
        timeout_seconds,
    )
    tests_text = capture_command(
        [
            xcrun,
            "xcresulttool",
            "get",
            "test-results",
            "tests",
            "--path",
            str(result_bundle),
        ],
        output / "xcresult-tests",
        timeout_seconds,
    )
    try:
        summary = json.loads(summary_text)
        tests = json.loads(tests_text)
    except json.JSONDecodeError as error:
        raise QualificationError("xcresulttool returned invalid JSON") from error
    write_json(output / "xcresult-summary.json", summary)
    write_json(output / "xcresult-tests.json", tests)
    return summary, tests


def base_test_command(
    xcodebuild: str,
    xctestrun: pathlib.Path,
    destination: str,
    only_testing: str,
    extra_arguments: Sequence[str],
) -> list[str]:
    return [
        xcodebuild,
        "-xctestrun",
        str(xctestrun),
        "-destination",
        destination,
        f"-only-testing:{only_testing}",
        "-parallel-testing-enabled",
        "NO",
        *extra_arguments,
    ]


def enumerate_tests(
    *,
    xcodebuild: str,
    xctestrun: pathlib.Path,
    destination: str,
    only_testing: str,
    expected_test_count: int,
    products_manifest_path: pathlib.Path,
    output: pathlib.Path,
    extra_arguments: Sequence[str],
    timeout_seconds: int,
) -> dict[str, Any]:
    xctestrun = require_xctestrun(xctestrun)
    only_testing = validate_only_testing(only_testing)
    extra_arguments = validate_extra_xcode_arguments(extra_arguments)
    if expected_test_count < 1:
        raise QualificationError("expected test count must be positive")
    if timeout_seconds < 1:
        raise QualificationError("per-invocation timeout must be positive")
    products_payload = read_json(products_manifest_path, "test-products manifest")
    if not isinstance(products_payload, dict) or not isinstance(
        products_payload.get("productsRoot"), str
    ):
        raise QualificationError("test-products manifest lacks productsRoot")
    require_separate_output(output, pathlib.Path(products_payload["productsRoot"]))
    output = require_empty_output(output, "enumeration output")
    try:
        products, _ = verify_products_manifest(products_manifest_path, xctestrun)
        raw_path = output / "enumeration.raw.json"
        command = base_test_command(
            xcodebuild, xctestrun, destination, only_testing, extra_arguments
        ) + [
            "-enumerate-tests",
            "-test-enumeration-style",
            "flat",
            "-test-enumeration-format",
            "json",
            "-test-enumeration-output-path",
            str(raw_path),
            "test-without-building",
        ]
        outcome = execute_logged(
            command, output / "process", timeout_seconds=timeout_seconds
        )
        if outcome.timed_out:
            raise QualificationError(
                f"test enumeration exceeded {timeout_seconds} seconds"
            )
        if outcome.status != 0:
            raise QualificationError(
                f"test enumeration failed with xcodebuild status {outcome.status}"
            )
        payload = read_json(raw_path, "Xcode test enumeration")
        records = collect_enumerated_test_records(payload, only_testing)
        identifiers = [record["identifier"] for record in records]
        if len(identifiers) != expected_test_count:
            raise QualificationError(
                f"expected {expected_test_count} enumerated tests; found {len(identifiers)}"
            )
        _, products_after = verify_products_manifest(products_manifest_path, xctestrun)
        manifest = {
            "schema": ENUMERATION_SCHEMA,
            "destination": destination,
            "expectedTestCount": expected_test_count,
            "onlyTesting": only_testing,
            "process": dataclasses.asdict(outcome),
            "productsManifestSHA256": sha256_file(products_manifest_path),
            "productsTreeSHA256": products_after["treeSHA256"],
            "rawEnumerationSHA256": sha256_file(raw_path),
            "rawTestIdentifiers": [record["rawIdentifier"] for record in records],
            "testIdentifiers": identifiers,
            "xctestrun": str(xctestrun),
            "xctestrunSHA256": products["xctestrunSHA256"],
        }
        write_json(output / "enumeration.json", manifest)
        write_json(output / "enumeration-status.json", {"status": "passed"})
        return manifest
    except Exception as error:
        write_json(
            output / "enumeration-status.json",
            {"error": str(error), "status": "failed", "type": type(error).__name__},
        )
        if isinstance(error, QualificationError):
            raise
        raise QualificationError(f"test enumeration failed: {error}") from error


def load_enumeration(
    path: pathlib.Path,
    xctestrun: pathlib.Path,
    destination: str,
    only_testing: str,
    expected_test_count: int,
) -> dict[str, Any]:
    payload = read_json(path, "saved test enumeration")
    if not isinstance(payload, dict) or payload.get("schema") != ENUMERATION_SCHEMA:
        raise QualificationError("saved test enumeration has an unsupported schema")
    checks = {
        "destination": destination,
        "expectedTestCount": expected_test_count,
        "onlyTesting": only_testing,
        "xctestrunSHA256": sha256_file(xctestrun),
    }
    for key, expected in checks.items():
        if payload.get(key) != expected:
            raise QualificationError(
                f"saved test enumeration {key} differs: "
                f"expected {expected!r}, found {payload.get(key)!r}"
            )
    identifiers = payload.get("testIdentifiers")
    if (
        not isinstance(identifiers, list)
        or any(not isinstance(value, str) for value in identifiers)
        or len(identifiers) != expected_test_count
        or len(set(identifiers)) != len(identifiers)
    ):
        raise QualificationError("saved test enumeration identifiers are invalid")
    return payload


def write_matrix_summary(
    output: pathlib.Path,
    *,
    status: str,
    only_testing: str,
    requested: int,
    runs: Sequence[dict[str, Any]],
    first_failure: dict[str, Any] | None = None,
    products_tree_sha256: str | None = None,
    reset_simulator_before_each_run: bool = False,
) -> dict[str, Any]:
    payload = {
        "schema": MATRIX_SCHEMA,
        "firstFailure": first_failure,
        "freshXcodebuildProcessCount": len(runs),
        "onlyTesting": only_testing,
        "passed": sum(1 for run in runs if run.get("valid") is True),
        "productsTreeSHA256": products_tree_sha256,
        "requested": requested,
        "runs": list(runs),
        "status": status,
        "simulatorResetBeforeEachRun": reset_simulator_before_each_run,
        "xcodebuildPIDs": [run.get("xcodebuildPID") for run in runs],
    }
    write_json(output / "matrix-summary.json", payload)
    return payload


def run_repetitions(
    *,
    xcodebuild: str,
    xcrun: str,
    xctestrun: pathlib.Path,
    destination: str,
    only_testing: str,
    count: int,
    expected_test_count: int,
    enumeration_path: pathlib.Path,
    products_manifest_path: pathlib.Path,
    output: pathlib.Path,
    extra_arguments: Sequence[str],
    timeout_seconds: int,
    reset_simulator_before_each_run: bool = False,
) -> dict[str, Any]:
    xctestrun = require_xctestrun(xctestrun)
    only_testing = validate_only_testing(only_testing)
    extra_arguments = validate_extra_xcode_arguments(extra_arguments)
    if not 1 <= count <= 1000:
        raise QualificationError("repetition count must be between 1 and 1000")
    if expected_test_count < 1:
        raise QualificationError("expected test count must be positive")
    if timeout_seconds < 1:
        raise QualificationError("per-invocation timeout must be positive")
    products_payload = read_json(products_manifest_path, "test-products manifest")
    if not isinstance(products_payload, dict) or not isinstance(
        products_payload.get("productsRoot"), str
    ):
        raise QualificationError("test-products manifest lacks productsRoot")
    require_separate_output(output, pathlib.Path(products_payload["productsRoot"]))
    output = require_empty_output(output, "matrix output")
    try:
        products, _ = verify_products_manifest(products_manifest_path, xctestrun)
        enumeration = load_enumeration(
            enumeration_path,
            xctestrun,
            destination,
            only_testing,
            expected_test_count,
        )
        if enumeration.get("productsTreeSHA256") != products["treeSHA256"]:
            raise QualificationError("enumeration used different compiled test products")
    except Exception as error:
        failure = {"error": str(error), "iteration": 0, "type": type(error).__name__}
        write_matrix_summary(
            output,
            status="failed",
            only_testing=only_testing,
            requested=count,
            runs=[],
            first_failure=failure,
            products_tree_sha256=products_payload.get("treeSHA256"),
            reset_simulator_before_each_run=reset_simulator_before_each_run,
        )
        if isinstance(error, QualificationError):
            raise
        raise QualificationError(f"matrix preflight failed: {error}") from error
    identifiers = enumeration["testIdentifiers"]
    runs: list[dict[str, Any]] = []
    for iteration in range(1, count + 1):
        iteration_output = output / f"iteration-{iteration:03d}"
        result_bundle = iteration_output / "result.xcresult"
        command = base_test_command(
            xcodebuild, xctestrun, destination, only_testing, extra_arguments
        ) + ["-resultBundlePath", str(result_bundle), "test-without-building"]
        try:
            reset_report = None
            if reset_simulator_before_each_run:
                reset_output = output / f"simulator-reset-{iteration:03d}"
                reset_report = reset_simulator(
                    xcrun=xcrun,
                    destination=destination,
                    output=reset_output,
                )
            outcome = execute_logged(
                command, iteration_output, timeout_seconds=timeout_seconds
            )
            run_record: dict[str, Any] = {
                "finishedAt": outcome.finished_at,
                "iteration": iteration,
                "startedAt": outcome.started_at,
                "valid": False,
                "xcodebuildPID": outcome.pid,
                "xcodebuildStatus": outcome.status,
                "timedOut": outcome.timed_out,
                "productsTreeSHA256": products["treeSHA256"],
            }
            if reset_report is not None:
                reset_manifest = (
                    output
                    / f"simulator-reset-{iteration:03d}"
                    / "simulator-reset.json"
                )
                run_record["simulatorReset"] = {
                    "manifest": str(reset_manifest),
                    "manifestSHA256": sha256_file(reset_manifest),
                    "stateAfterBoot": reset_report["stateAfterBoot"],
                    "stateBefore": reset_report["stateBefore"],
                }
            runs.append(run_record)
            if outcome.timed_out:
                raise QualificationError(
                    f"xcodebuild iteration exceeded {timeout_seconds} seconds"
                )
            if not result_bundle.is_dir():
                raise QualificationError("xcodebuild did not produce the required XCResult")
            summary, tests = extract_xcresult(
                xcrun, result_bundle, iteration_output, timeout_seconds
            )
            verification = verify_passing_xcresult(
                summary, tests, identifiers, expected_test_count, destination
            )
            if outcome.status != 0:
                raise QualificationError(
                    f"xcodebuild failed with status {outcome.status} despite XCResult content"
                )
            run_record["valid"] = True
            run_record["observedTestCount"] = len(verification["observedIdentifiers"])
            write_json(
                iteration_output / "qualification-run.json",
                {
                    "schema": RUN_SCHEMA,
                    **run_record,
                    "verification": verification,
                },
            )
        except Exception as error:
            failure = {
                "error": str(error),
                "iteration": iteration,
                "type": type(error).__name__,
            }
            classification = getattr(error, "classification", None)
            if isinstance(classification, str):
                failure["classification"] = classification
            try:
                verify_products_manifest(products_manifest_path, xctestrun)
            except Exception as products_error:
                failure["productsError"] = str(products_error)
            if runs and runs[-1].get("iteration") == iteration:
                write_json(
                    iteration_output / "qualification-run.json",
                    {"schema": RUN_SCHEMA, **runs[-1], "failure": failure},
                )
            write_matrix_summary(
                output,
                status="failed",
                only_testing=only_testing,
                requested=count,
                runs=runs,
                first_failure=failure,
                products_tree_sha256=products["treeSHA256"],
                reset_simulator_before_each_run=reset_simulator_before_each_run,
            )
            if isinstance(error, QualificationError):
                raise
            raise QualificationError(f"iteration {iteration} failed: {error}") from error
    try:
        _, products_after = verify_products_manifest(products_manifest_path, xctestrun)
    except Exception as error:
        failure = {
            "error": str(error),
            "iteration": count,
            "type": type(error).__name__,
        }
        write_matrix_summary(
            output,
            status="failed",
            only_testing=only_testing,
            requested=count,
            runs=runs,
            first_failure=failure,
            products_tree_sha256=products["treeSHA256"],
            reset_simulator_before_each_run=reset_simulator_before_each_run,
        )
        if isinstance(error, QualificationError):
            raise
        raise QualificationError(f"matrix product-custody check failed: {error}") from error
    return write_matrix_summary(
        output,
        status="passed",
        only_testing=only_testing,
        requested=count,
        runs=runs,
        products_tree_sha256=products_after["treeSHA256"],
        reset_simulator_before_each_run=reset_simulator_before_each_run,
    )


def evidence_files(root: pathlib.Path, sums_path: pathlib.Path) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        if path == sums_path:
            continue
        if path.is_symlink():
            raise QualificationError(f"evidence must not contain symlinks: {path}")
        relative = path.relative_to(root).as_posix()
        if "\n" in relative or "\r" in relative:
            raise QualificationError(f"evidence path is ambiguous in SHA256SUMS: {relative!r}")
        if path.is_file():
            files.append(path)
        elif not path.is_dir():
            raise QualificationError(f"evidence contains a special file: {path}")
    return files


def seal_evidence(root: pathlib.Path, output_name: str = "SHA256SUMS") -> dict[str, Any]:
    root = root.resolve()
    if not root.is_dir():
        raise QualificationError(f"evidence directory is missing: {root}")
    if pathlib.PurePath(output_name).name != output_name or output_name in {"", ".", ".."}:
        raise QualificationError("SHA256SUMS output name must be a plain file name")
    sums_path = root / output_name
    if sums_path.exists() or sums_path.is_symlink():
        raise QualificationError(f"evidence is already sealed: {sums_path}")
    files = evidence_files(root, sums_path)
    if not files:
        raise QualificationError("cannot seal an empty evidence directory")
    first = [(path, sha256_file(path)) for path in files]
    second = [(path, sha256_file(path)) for path in evidence_files(root, sums_path)]
    if first != second:
        raise QualificationError("evidence changed while SHA256SUMS was being prepared")
    lines = [f"{digest}  {path.relative_to(root).as_posix()}" for path, digest in first]
    sums_path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    final = [(path, sha256_file(path)) for path in evidence_files(root, sums_path)]
    if first != final:
        sums_path.unlink()
        raise QualificationError("evidence changed while SHA256SUMS was being sealed")
    return {
        "fileCount": len(lines),
        "sha256sums": str(sums_path),
        "sha256sumsSHA256": sha256_file(sums_path),
    }


def add_xcode_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--xcode-arg",
        action="append",
        default=[],
        help="Allowlisted strict package argument; use --xcode-arg=-flag for flags.",
    )
    parser.add_argument("--xcode-args-file", type=pathlib.Path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    locate = subparsers.add_parser("locate-xctestrun")
    locate.add_argument("--products-root", type=pathlib.Path, required=True)
    locate.add_argument("--output", type=pathlib.Path, required=True)

    products = subparsers.add_parser("hash-products")
    products.add_argument("--products-root", type=pathlib.Path, required=True)
    products.add_argument("--xctestrun", type=pathlib.Path)
    products.add_argument("--output", type=pathlib.Path, required=True)

    enumeration = subparsers.add_parser("enumerate")
    enumeration.add_argument("--xcodebuild", default="xcodebuild")
    enumeration.add_argument("--xctestrun", type=pathlib.Path, required=True)
    enumeration.add_argument("--destination", required=True)
    enumeration.add_argument("--only-testing", required=True)
    enumeration.add_argument("--expected-test-count", type=int, required=True)
    enumeration.add_argument("--products-manifest", type=pathlib.Path, required=True)
    enumeration.add_argument("--timeout-seconds", type=int, required=True)
    enumeration.add_argument("--output", type=pathlib.Path, required=True)
    add_xcode_arguments(enumeration)

    narrow = subparsers.add_parser("narrow-enumeration")
    narrow.add_argument("--source", type=pathlib.Path, required=True)
    narrow.add_argument("--xctestrun", type=pathlib.Path, required=True)
    narrow.add_argument("--destination", required=True)
    narrow.add_argument("--source-only-testing", required=True)
    narrow.add_argument("--source-expected-test-count", type=int, required=True)
    narrow.add_argument("--only-testing", required=True)
    narrow.add_argument("--output", type=pathlib.Path, required=True)

    run = subparsers.add_parser("run")
    run.add_argument("--xcodebuild", default="xcodebuild")
    run.add_argument("--xcrun", default="xcrun")
    run.add_argument("--xctestrun", type=pathlib.Path, required=True)
    run.add_argument("--destination", required=True)
    run.add_argument("--only-testing", required=True)
    run.add_argument("--count", type=int, required=True)
    run.add_argument("--expected-test-count", type=int, required=True)
    run.add_argument("--enumeration", type=pathlib.Path, required=True)
    run.add_argument("--products-manifest", type=pathlib.Path, required=True)
    run.add_argument("--timeout-seconds", type=int, required=True)
    run.add_argument("--output", type=pathlib.Path, required=True)
    run.add_argument(
        "--reset-simulator-before-each-run",
        action="store_true",
        help=(
            "Before each fresh xcodebuild process, synchronously reboot the exact "
            "destination and wait for CoreSimulator boot completion."
        ),
    )
    add_xcode_arguments(run)

    seal = subparsers.add_parser("seal")
    seal.add_argument("--evidence", type=pathlib.Path, required=True)
    seal.add_argument("--output-name", default="SHA256SUMS")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "locate-xctestrun":
            path = locate_xctestrun(args.products_root)
            require_separate_output(args.output, args.products_root)
            write_new_json(
                args.output,
                {
                    "path": str(path),
                    "sha256": sha256_file(path),
                    "size": path.stat().st_size,
                },
            )
            print(path)
        elif args.command == "hash-products":
            require_separate_output(args.output, args.products_root)
            manifest = stable_test_product_inventory(
                args.products_root, args.xctestrun
            )
            write_new_json(args.output, manifest)
            print(json.dumps(manifest, sort_keys=True))
        elif args.command == "enumerate":
            extra = read_extra_xcode_arguments(args.xcode_arg, args.xcode_args_file)
            manifest = enumerate_tests(
                xcodebuild=args.xcodebuild,
                xctestrun=args.xctestrun,
                destination=args.destination,
                only_testing=args.only_testing,
                expected_test_count=args.expected_test_count,
                products_manifest_path=args.products_manifest,
                output=args.output,
                extra_arguments=extra,
                timeout_seconds=args.timeout_seconds,
                reset_simulator_before_each_run=args.reset_simulator_before_each_run,
            )
            print(json.dumps(manifest, sort_keys=True))
        elif args.command == "narrow-enumeration":
            manifest = narrow_enumeration(
                source_path=args.source,
                xctestrun=args.xctestrun,
                destination=args.destination,
                source_only_testing=args.source_only_testing,
                source_expected_test_count=args.source_expected_test_count,
                only_testing=args.only_testing,
                output=args.output,
            )
            print(json.dumps(manifest, sort_keys=True))
        elif args.command == "run":
            extra = read_extra_xcode_arguments(args.xcode_arg, args.xcode_args_file)
            manifest = run_repetitions(
                xcodebuild=args.xcodebuild,
                xcrun=args.xcrun,
                xctestrun=args.xctestrun,
                destination=args.destination,
                only_testing=args.only_testing,
                count=args.count,
                expected_test_count=args.expected_test_count,
                enumeration_path=args.enumeration,
                products_manifest_path=args.products_manifest,
                output=args.output,
                extra_arguments=extra,
                timeout_seconds=args.timeout_seconds,
            )
            print(json.dumps(manifest, sort_keys=True))
        elif args.command == "seal":
            print(json.dumps(seal_evidence(args.evidence, args.output_name), sort_keys=True))
        else:  # pragma: no cover - argparse makes this unreachable.
            raise QualificationError(f"unsupported command: {args.command}")
    except QualificationError as error:
        print(f"qualification error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
