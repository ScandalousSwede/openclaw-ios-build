#!/usr/bin/env python3
"""Create a secret-free retained log for the AIES signed release lane."""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil


ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PRIVATE_KEY = re.compile(
    r"-----BEGIN (?:EC |RSA )?PRIVATE KEY-----.*?"
    r"-----END (?:EC |RSA )?PRIVATE KEY-----",
    re.DOTALL,
)
AUTH_VALUE = re.compile(
    r"(?P<prefix>-(?:authenticationKeyPath|authenticationKeyID|"
    r"authenticationKeyIssuerID)(?:\s+|=))"
    r"(?:'[^']*'|\"[^\"]*\"|\S+)"
)
REDACTION_ENV = {
    "ASC_KEY_PATH": "[REDACTED_ASC_KEY_PATH]",
    "ASC_KEY_ID": "[REDACTED_ASC_KEY_ID]",
    "ASC_ISSUER_ID": "[REDACTED_ASC_ISSUER_ID]",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def sanitize_text(text: str, redactions: dict[str, str]) -> str:
    sanitized = ANSI_ESCAPE.sub("", text)
    sanitized = PRIVATE_KEY.sub("[REDACTED_PRIVATE_KEY]", sanitized)
    for value, placeholder in sorted(
        redactions.items(), key=lambda item: len(item[0]), reverse=True
    ):
        if value:
            sanitized = sanitized.replace(value, placeholder)
    return AUTH_VALUE.sub(
        lambda match: f"{match.group('prefix')}[REDACTED_AUTH_VALUE]",
        sanitized,
    )


def main() -> None:
    args = parse_args()
    if not args.input.is_file():
        raise ValueError(f"missing raw release log: {args.input}")
    if args.input.resolve() == args.output.resolve():
        raise ValueError("raw and retained release log paths must differ")

    configured: dict[str, str] = {}
    for key, placeholder in REDACTION_ENV.items():
        value = os.environ.get(key, "").strip()
        if value:
            configured[value] = placeholder
    raw = args.input.read_text(encoding="utf-8", errors="replace")
    sanitized = sanitize_text(raw, configured)
    if "BEGIN PRIVATE KEY" in sanitized or "END PRIVATE KEY" in sanitized:
        raise ValueError("retained release log still contains a private-key marker")
    if any(value in sanitized for value in configured):
        raise ValueError("retained release log still contains configured ASC metadata")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    for candidate in (args.output, temporary):
        if candidate.is_symlink() or candidate.is_file():
            candidate.unlink()
        elif candidate.exists():
            raise ValueError(f"refusing non-file release-log path: {candidate}")
    try:
        temporary.write_text(sanitized, encoding="utf-8")
        shutil.move(temporary, args.output)
    except BaseException:
        for candidate in (args.output, temporary):
            if candidate.is_symlink() or candidate.is_file():
                candidate.unlink()
        raise


if __name__ == "__main__":
    main()
