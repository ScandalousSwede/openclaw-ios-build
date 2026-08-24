from __future__ import annotations

import pathlib
import tempfile
import unittest
from unittest import mock

import sanitize_aies_release_log as sanitizer


class AIESReleaseLogSanitizerTests(unittest.TestCase):
    def test_sanitizes_authentication_values_private_key_and_ansi(self) -> None:
        raw = (
            "\x1b[31mxcodebuild -authenticationKeyPath /private/key.p8 "
            "-authenticationKeyID KEY1234567 "
            "-authenticationKeyIssuerID 11111111-2222-3333-4444-555555555555\x1b[0m\n"
            "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----\n"
        )
        result = sanitizer.sanitize_text(
            raw,
            {
                "/private/key.p8": "[PATH]",
                "KEY1234567": "[KEY_ID]",
                "11111111-2222-3333-4444-555555555555": "[ISSUER]",
            },
        )
        self.assertNotIn("\x1b", result)
        self.assertNotIn("/private/key.p8", result)
        self.assertNotIn("KEY1234567", result)
        self.assertNotIn("11111111-2222-3333-4444-555555555555", result)
        self.assertNotIn("BEGIN PRIVATE KEY", result)
        self.assertEqual(result.count("[REDACTED_AUTH_VALUE]"), 3)
        self.assertIn("[REDACTED_PRIVATE_KEY]", result)

    def test_main_writes_only_sanitized_output(self) -> None:
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            source = temp / "raw.log"
            output = temp / "retained.log"
            source.write_text(
                "-authenticationKeyID SECRETKEY1\nfinished\n", encoding="utf-8"
            )
            args = type("Args", (), {"input": source, "output": output})()
            with (
                mock.patch.object(sanitizer, "parse_args", return_value=args),
                mock.patch.dict("os.environ", {"ASC_KEY_ID": "SECRETKEY1"}),
            ):
                sanitizer.main()
            self.assertTrue(output.is_file())
            retained = output.read_text(encoding="utf-8")
            self.assertNotIn("SECRETKEY1", retained)
            self.assertIn("finished", retained)


if __name__ == "__main__":
    unittest.main()
