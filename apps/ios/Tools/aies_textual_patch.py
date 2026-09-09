"""Apply and verify the declared Textual repair in the existing strict build root."""
from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import stat

PROVENANCE = "apps/ios/PackageAuthority/textual-balanced-concatenation-patch.json"
SOURCE = "Sources/Textual/Internal/TextFragment/TextBuilder.swift"


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
    if set(patch) != {"schema", "packageIdentity", "repository", "revision", "path", "beforeSHA256", "afterSHA256", "replacement", "purpose"}:
        raise PatchError("Textual patch provenance fields differ")
    if patch["schema"] != "aies.ios.checkout-source-patch.v1" or patch["packageIdentity"] != "textual" or patch["path"] != SOURCE:
        raise PatchError("Textual patch identity differs")
    pins = [pin for pin in manifest["pins"] if pin["identity"] == "textual"]
    if len(pins) != 1 or (pins[0]["location"], pins[0]["revision"]) != (patch["repository"], patch["revision"]):
        raise PatchError("Textual patch does not match the selected dependency")
    for field in ("beforeSHA256", "afterSHA256"):
        value = patch[field]
        if not isinstance(value, str) or len(value) != 64 or any(char not in "0123456789abcdef" for char in value):
            raise PatchError("invalid Textual source digest")
    replacement = patch["replacement"]
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
    target = selected / SOURCE
    if target.resolve() != selected.resolve() / SOURCE or target.is_symlink():
        raise PatchError("Textual source escapes checkout custody")
    original = git("show", "HEAD:" + SOURCE)
    if digest(original) != patch["beforeSHA256"]:
        raise PatchError("Textual original source digest differs")
    replacement = patch["replacement"]
    if original.decode().count(replacement["before"]) != 1:
        raise PatchError("Textual replacement does not match exactly once")
    expected = original.decode().replace(replacement["before"], replacement["after"]).encode()
    if digest(expected) != patch["afterSHA256"]:
        raise PatchError("Textual replacement digest differs")
    content = target.read_bytes()
    status = git("status", "--porcelain=v1", "--untracked-files=all").decode()
    expected_status = " M " + SOURCE + "\n"
    if content == original and status == "" and apply:
        if archive is None:
            raise PatchError("Textual original source archive is required")
        archive.mkdir(parents=True, exist_ok=True)
        archived = archive / "TextBuilder-original.swift"
        if archived.exists():
            if archived.read_bytes() != original:
                raise PatchError("Textual source archive conflicts")
        else:
            with archived.open("xb") as stream:
                stream.write(original)
        # SwiftPM makes resolved source files read-only. Permit this one
        # already-verified delta, then restore its exact original mode even
        # if writing fails; never unlock the package tree recursively.
        original_mode = stat.S_IMODE(target.stat().st_mode)
        try:
            target.chmod(original_mode | stat.S_IWUSR)
            target.write_bytes(expected)
        finally:
            target.chmod(original_mode)
        content = target.read_bytes()
        status = git("status", "--porcelain=v1", "--untracked-files=all").decode()
    if content != expected or status != expected_status:
        raise PatchError("Textual checkout differs from the exact governed patch")
    return {"packageIdentity": "textual", "checkout": str(selected), "revision": patch["revision"], "source": SOURCE, "beforeSHA256": digest(original), "afterSHA256": digest(content), "provenanceSHA256": digest((root / PROVENANCE).read_bytes()), "status": "verified"}
