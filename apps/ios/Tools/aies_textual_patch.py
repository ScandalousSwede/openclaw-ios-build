"""Apply and verify the declared Textual repair in the existing strict build root."""
from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import stat

PROVENANCE = "apps/ios/PackageAuthority/textual-balanced-concatenation-patch.json"
SOURCE = "Sources/Textual/Internal/TextFragment/TextBuilder.swift"
PARAGRAPH = "Sources/Textual/Internal/StructuredText/Paragraph.swift"
SOURCES = (SOURCE, PARAGRAPH)


class PatchError(ValueError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def declaration(root: pathlib.Path, manifest: dict) -> dict:
    entries = [entry for entry in manifest["sourcePatches"] if entry.get("packageIdentity") == "textual"]
    if len(entries) != 1 or set(entries[0]) != {"packageIdentity", "path", "sha256"}:
        raise PatchError("exactly one Textual patch declaration is required")
    entry = entries[0]
    if entry["path"] != PROVENANCE:
        raise PatchError("unexpected Textual patch provenance path")
    payload = (root / PROVENANCE).read_bytes()
    if digest(payload) != entry["sha256"]:
        raise PatchError("Textual patch provenance digest differs")
    patch = json.loads(payload)
    if set(patch) != {"schema", "packageIdentity", "repository", "revision", "files", "purpose"}:
        raise PatchError("Textual patch provenance fields differ")
    if patch["schema"] != "aies.ios.checkout-source-patch.v2" or patch["packageIdentity"] != "textual":
        raise PatchError("Textual patch identity differs")
    pins = [pin for pin in manifest["pins"] if pin["identity"] == "textual"]
    if len(pins) != 1 or (pins[0]["location"], pins[0]["revision"]) != (patch["repository"], patch["revision"]):
        raise PatchError("Textual patch does not match the selected dependency")
    files = patch["files"]
    if not isinstance(files, list) or len(files) != len(SOURCES):
        raise PatchError("Textual source file set differs")
    for record, source in zip(files, SOURCES):
        if not isinstance(record, dict) or set(record) != {"path", "beforeSHA256", "afterSHA256", "replacement"} or record["path"] != source:
            raise PatchError("Textual source file set differs")
        for field in ("beforeSHA256", "afterSHA256"):
            value = record[field]
            if not isinstance(value, str) or len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
                raise PatchError("invalid Textual source digest")
        replacement = record["replacement"]
        if not isinstance(replacement, dict) or set(replacement) != {"before", "after"} or not all(isinstance(value, str) and value for value in replacement.values()):
            raise PatchError("invalid Textual replacement")
    return patch


def checkout(source_packages: pathlib.Path, workspace_state: pathlib.Path) -> pathlib.Path:
    dependencies = json.loads(workspace_state.read_text())["object"]["dependencies"]
    matches = [entry for entry in dependencies if entry.get("packageRef", {}).get("identity") == "textual"]
    if len(matches) != 1:
        raise PatchError("exactly one Textual checkout is required")
    subpath = matches[0].get("subpath")
    if not isinstance(subpath, str) or subpath in {"", ".", ".."} or "/" in subpath or "\\" in subpath:
        raise PatchError("unsafe Textual checkout subpath")
    checkouts = source_packages.resolve() / "checkouts"
    selected = checkouts / subpath
    if checkouts.is_symlink() or selected.is_symlink() or selected.resolve().parent != checkouts.resolve():
        raise PatchError("Textual checkout escapes source custody")
    return selected


def verify(root: pathlib.Path, manifest: dict, workspace_state: pathlib.Path, source_packages: pathlib.Path, *, apply: bool = False, archive: pathlib.Path | None = None) -> dict:
    patch = declaration(root, manifest)
    selected = checkout(source_packages, workspace_state)

    def git(*args: str) -> bytes:
        return subprocess.check_output(["git", *args], cwd=selected)

    if git("rev-parse", "HEAD").decode().strip() != patch["revision"]:
        raise PatchError("Textual checkout revision differs")
    prepared = []
    for record in patch["files"]:
        source = record["path"]
        target = selected / source
        if target.resolve() != selected.resolve() / source or target.is_symlink():
            raise PatchError("Textual source escapes checkout custody")
        original = git("show", "HEAD:" + source)
        if digest(original) != record["beforeSHA256"]:
            raise PatchError("Textual original source digest differs")
        replacement = record["replacement"]
        if original.decode().count(replacement["before"]) != 1:
            raise PatchError("Textual replacement does not match exactly once")
        expected = original.decode().replace(replacement["before"], replacement["after"]).encode()
        if digest(expected) != record["afterSHA256"]:
            raise PatchError("Textual replacement digest differs")
        prepared.append((source, target, original, expected))
    status = git("status", "--porcelain=v1", "--untracked-files=all").decode()
    expected_status = "".join(" M " + source + "\n" for source in sorted(SOURCES))
    original_checkout = status == "" and all(target.read_bytes() == original for _, target, original, _ in prepared)
    if original_checkout and apply:
        if archive is None:
            raise PatchError("Textual original source archive is required")
        archive.mkdir(parents=True, exist_ok=True)
        # Validate every archive before mutating either governed source file.
        for source, _, original, _ in prepared:
            archived = archive / (pathlib.Path(source).stem + "-original.swift")
            if archived.exists() and archived.read_bytes() != original:
                raise PatchError("Textual source archive conflicts")
        for source, _, original, _ in prepared:
            archived = archive / (pathlib.Path(source).stem + "-original.swift")
            if not archived.exists():
                with archived.open("xb") as stream:
                    stream.write(original)
        # SwiftPM source is read-only. Unlock only the two verified files and
        # restore modes even on failure. Partial writes fail closed on re-entry.
        for _, target, _, expected in prepared:
            original_mode = stat.S_IMODE(target.stat().st_mode)
            try:
                target.chmod(original_mode | stat.S_IWUSR)
                target.write_bytes(expected)
            finally:
                target.chmod(original_mode)
        status = git("status", "--porcelain=v1", "--untracked-files=all").decode()
    if status != expected_status or any(target.read_bytes() != expected for _, target, _, expected in prepared):
        raise PatchError("Textual checkout differs from the exact governed patch")
    return {"packageIdentity": "textual", "checkout": str(selected), "revision": patch["revision"],
            "files": [{"source": source, "beforeSHA256": digest(original), "afterSHA256": digest(target.read_bytes())}
                      for source, target, original, _ in prepared],
            "provenanceSHA256": digest((root / PROVENANCE).read_bytes()), "status": "verified"}
