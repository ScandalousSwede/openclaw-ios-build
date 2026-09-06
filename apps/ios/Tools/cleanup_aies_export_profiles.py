"""Remove only cached profiles bound to the verified exported IPA on this runner."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat

from verify_aies_internal_signing import validate_report_contract

CACHES = (
    ("Library", "Developer", "Xcode", "UserData", "Provisioning Profiles"),
    ("Library", "MobileDevice", "Provisioning Profiles"),
)
UUID = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}")


def cleanup(report_path: pathlib.Path, home: pathlib.Path) -> int:
    # Export can fail before producing a receipt. Leave unknown cache entries
    # alone; the existing final cache check will truthfully report incomplete.
    if not report_path.exists() and not report_path.is_symlink():
        return 0
    flags = os.O_RDONLY | os.O_NOFOLLOW
    with os.fdopen(os.open(report_path, flags), "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 4_000_000:
            raise ValueError("signing report is not a bounded regular file")
        report = json.load(handle)
    validate_report_contract(report, archive_only=False)
    expected = {}
    for bundle in report["ipa"]["bundles"]:
        profile = bundle["profile"]
        uuid = profile["uuid"].lower()
        digest = profile["embedded_profile_sha256"]
        if not UUID.fullmatch(uuid) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("invalid exported profile identity")
        if uuid in expected and expected[uuid] != digest:
            raise ValueError("conflicting exported profile identity")
        expected[uuid] = digest

    removed = 0
    for components in CACHES:
        descriptors = []
        try:
            current = os.open(home, flags | os.O_DIRECTORY)
            descriptors.append(current)
            for component in components:
                current = os.open(component, flags | os.O_DIRECTORY, dir_fd=current)
                descriptors.append(current)
            for name in os.listdir(current):
                uuid, extension = os.path.splitext(name)
                digest = expected.get(uuid.lower())
                if extension not in (".mobileprovision", ".provisionprofile") or digest is None:
                    continue
                with os.fdopen(os.open(name, flags, dir_fd=current), "rb") as handle:
                    opened = os.fstat(handle.fileno())
                    if not stat.S_ISREG(opened.st_mode) or opened.st_size > 5_000_000:
                        raise ValueError("cached profile is not a bounded regular file")
                    if hashlib.sha256(handle.read()).hexdigest() != digest:
                        raise ValueError("cached profile differs from verified exported profile")
                checked = os.stat(name, dir_fd=current, follow_symlinks=False)
                if (checked.st_dev, checked.st_ino) != (opened.st_dev, opened.st_ino):
                    raise ValueError("cached profile changed during cleanup")
                os.unlink(name, dir_fd=current)
                removed += 1
        except FileNotFoundError:
            # Missing cache roots and previously removed files are idempotent.
            continue
        finally:
            for descriptor in reversed(descriptors):
                os.close(descriptor)
    return removed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=pathlib.Path, required=True)
    args = parser.parse_args()
    print(f"Verified exported profiles removed: {cleanup(args.report, pathlib.Path.home())}")
