#!/usr/bin/env python3
"""Run exact, already-built SwiftPM test repetitions with custody evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
from typing import Any, Sequence


SCHEMA = "aies.swift.test-without-rebuild-matrix.v1"
PRODUCTS_SCHEMA = "aies.swift.test-products.v1"
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PASS_SUMMARY = re.compile(
    r"Test run with (?P<tests>[0-9]+) tests? in (?P<suites>[0-9]+) suites? "
    r"passed after [0-9.]+ seconds?\."
)


class QualificationError(RuntimeError):
    """A fail-closed Swift qualification error."""


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def require_regular_directory(path: pathlib.Path, label: str) -> pathlib.Path:
    path = path.resolve()
    if not path.is_dir() or path.is_symlink():
        raise QualificationError(f"{label} is not a regular directory: {path}")
    return path


def assert_disjoint(output: pathlib.Path, protected: Sequence[pathlib.Path]) -> pathlib.Path:
    output = output.resolve()
    for candidate in protected:
        candidate = candidate.resolve()
        if output == candidate or output in candidate.parents or candidate in output.parents:
            raise QualificationError(
                f"evidence output overlaps protected test input: {output} and {candidate}"
            )
    return output


def product_inventory(root: pathlib.Path) -> dict[str, Any]:
    root = require_regular_directory(root, "Swift test-products root")
    files: list[dict[str, Any]] = []
    combined = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda value: value.relative_to(root).as_posix()):
        if path.is_symlink():
            raise QualificationError(f"test products contain a symlink: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        digest = sha256_file(path)
        size = path.stat().st_size
        files.append({"path": relative, "sha256": digest, "bytes": size})
        combined.update(relative.encode("utf-8") + b"\0")
        combined.update(digest.encode("ascii") + b"\0")
        combined.update(str(size).encode("ascii") + b"\n")
    if not files:
        raise QualificationError("Swift test-products root contains no files")
    return {
        "schema": PRODUCTS_SCHEMA,
        "root": str(root),
        "fileCount": len(files),
        "treeSHA256": combined.hexdigest(),
        "files": files,
    }


def load_product_manifest(path: pathlib.Path, root: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise QualificationError(f"invalid Swift product manifest: {path}") from error
    current = product_inventory(root)
    if value != current:
        raise QualificationError("Swift test products differ from the sealed manifest")
    return current


def parse_pass_summary(log: str, expected_tests: int, expected_suites: int) -> dict[str, int]:
    clean = ANSI.sub("", log)
    matches = list(PASS_SUMMARY.finditer(clean))
    if not matches:
        raise QualificationError("Swift Testing passing summary is absent")
    match = matches[-1]
    observed = {
        "tests": int(match.group("tests")),
        "suites": int(match.group("suites")),
    }
    if observed != {"tests": expected_tests, "suites": expected_suites}:
        raise QualificationError(
            "Swift Testing summary count mismatch: "
            f"expected {expected_tests}/{expected_suites}, observed "
            f"{observed['tests']}/{observed['suites']}"
        )
    return observed


def execute(
    arguments: list[str], log_path: pathlib.Path, timeout_seconds: int
) -> dict[str, Any]:
    started = utc_now()
    with log_path.open("wb") as log:
        process = subprocess.Popen(arguments, stdout=log, stderr=subprocess.STDOUT)
        try:
            status = process.wait(timeout=timeout_seconds)
            timed_out = False
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            status = process.returncode
            timed_out = True
    return {
        "pid": process.pid,
        "status": status,
        "timedOut": timed_out,
        "startedAt": started,
        "finishedAt": utc_now(),
    }


def run_matrix(args: argparse.Namespace) -> dict[str, Any]:
    package = require_regular_directory(pathlib.Path(args.package_path), "package root")
    products = require_regular_directory(pathlib.Path(args.products_root), "products root")
    output = assert_disjoint(pathlib.Path(args.output), [package, products])
    if output.exists():
        if not output.is_dir() or output.is_symlink() or any(output.iterdir()):
            raise QualificationError(f"output must be a new or empty regular directory: {output}")
    else:
        output.mkdir(parents=True)
    if args.count < 1 or args.expected_test_count < 1 or args.expected_suite_count < 1:
        raise QualificationError("counts must be positive")
    if not args.filter or any(character in args.filter for character in "\0\r\n"):
        raise QualificationError("test filter must be non-empty and single-line")
    if args.timeout_seconds < 1 or args.timeout_seconds > 3600:
        raise QualificationError("timeout must be between 1 and 3600 seconds")

    manifest_path = pathlib.Path(args.products_manifest).resolve()
    baseline = load_product_manifest(manifest_path, products)
    resolved = pathlib.Path(args.resolved).resolve()
    if not resolved.is_file() or resolved.is_symlink():
        raise QualificationError(f"resolved file is missing or unsafe: {resolved}")
    resolved_hash = sha256_file(resolved)
    command = [
        args.swift,
        "test",
        "--package-path",
        str(package),
        "--skip-build",
        "--force-resolved-versions",
        "--no-parallel",
        "--filter",
        args.filter,
    ]
    records: list[dict[str, Any]] = []
    for iteration in range(1, args.count + 1):
        iteration_root = output / f"iteration-{iteration:03d}"
        iteration_root.mkdir()
        write_json(
            iteration_root / "command.json",
            {"arguments": command, "rendered": shlex.join(command), "shell": False},
        )
        outcome = execute(command, iteration_root / "swift-test.log", args.timeout_seconds)
        (iteration_root / "exit-status.txt").write_text(
            f"{outcome['status']}\n", encoding="utf-8", newline="\n"
        )
        record = {"iteration": iteration, **outcome}
        records.append(record)
        try:
            if outcome["timedOut"]:
                raise QualificationError("Swift test process exceeded its bounded timeout")
            if outcome["status"] != 0:
                raise QualificationError(
                    f"Swift test process exited with status {outcome['status']}"
                )
            log = (iteration_root / "swift-test.log").read_text(
                encoding="utf-8", errors="replace"
            )
            record["summary"] = parse_pass_summary(
                log, args.expected_test_count, args.expected_suite_count
            )
            if sha256_file(resolved) != resolved_hash:
                raise QualificationError("Package.resolved changed during the matrix")
            current = product_inventory(products)
            if current != baseline:
                raise QualificationError("Swift test products changed during the matrix")
            record["valid"] = True
            write_json(iteration_root / "result.json", record)
        except (OSError, QualificationError) as error:
            record.update({"valid": False, "error": str(error)})
            write_json(iteration_root / "result.json", record)
            report = {
                "schema": SCHEMA,
                "status": "failed",
                "filter": args.filter,
                "requested": args.count,
                "passed": iteration - 1,
                "attempted": iteration,
                "expectedTestCount": args.expected_test_count,
                "expectedSuiteCount": args.expected_suite_count,
                "productsTreeSHA256": baseline["treeSHA256"],
                "resolvedSHA256": resolved_hash,
                "processes": records,
                "firstFailure": record,
            }
            write_json(output / "matrix-summary.json", report)
            raise
    report = {
        "schema": SCHEMA,
        "status": "passed",
        "filter": args.filter,
        "requested": args.count,
        "passed": args.count,
        "attempted": args.count,
        "expectedTestCount": args.expected_test_count,
        "expectedSuiteCount": args.expected_suite_count,
        "productsTreeSHA256": baseline["treeSHA256"],
        "resolvedSHA256": resolved_hash,
        "freshSwiftProcessCount": len({record["pid"] for record in records}),
        "swiftPIDs": [record["pid"] for record in records],
        "processes": records,
    }
    if report["freshSwiftProcessCount"] != args.count:
        raise QualificationError("Swift process IDs were not unique across repetitions")
    write_json(output / "matrix-summary.json", report)
    print(json.dumps(report, indent=2, sort_keys=True))
    return report


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="command", required=True)
    inventory = sub.add_parser("hash-products")
    inventory.add_argument("--products-root", required=True)
    inventory.add_argument("--output", required=True)
    run_parser = sub.add_parser("run")
    run_parser.add_argument("--swift", default="swift")
    run_parser.add_argument("--package-path", required=True)
    run_parser.add_argument("--products-root", required=True)
    run_parser.add_argument("--products-manifest", required=True)
    run_parser.add_argument("--resolved", required=True)
    run_parser.add_argument("--filter", required=True)
    run_parser.add_argument("--count", type=int, required=True)
    run_parser.add_argument("--expected-test-count", type=int, required=True)
    run_parser.add_argument("--expected-suite-count", type=int, default=1)
    run_parser.add_argument("--timeout-seconds", type=int, required=True)
    run_parser.add_argument("--output", required=True)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "hash-products":
            report = product_inventory(pathlib.Path(args.products_root))
            write_json(pathlib.Path(args.output), report)
            print(json.dumps(report, indent=2, sort_keys=True))
        elif args.command == "run":
            run_matrix(args)
        else:  # pragma: no cover
            raise QualificationError(f"unsupported command: {args.command}")
    except (OSError, QualificationError) as error:
        print(f"SWIFT_QUALIFICATION_ERROR: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
