"""Synthetic reviewer transport regression; no model, config or repository access."""
import importlib.machinery
import importlib.util
import io
from pathlib import Path
import sys
import unittest

SOURCE = Path(__file__).with_name("autoreview")
loader = importlib.machinery.SourceFileLoader("autoreview_transport_test", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
helper = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = helper
loader.exec_module(helper)

class ReviewerUTF8Tests(unittest.TestCase):
    def test_both_reviewers_roundtrip_non_ascii_with_legacy_parent_encoding(self):
        # Invoke this test on Windows with -X utf8=0 and PYTHONIOENCODING=cp1252.
        # Child is a synthetic UTF-8 CLI, independent of the inherited locale.
        text = "review \u2192 \u65e5\u672c\u8a9e \U0001f600\n"
        child = (
            "import os,sys,threading; "
            "timer=threading.Timer(3,lambda:os._exit(77));timer.start(); "
            "sys.stdin.reconfigure(encoding='utf-8'); "
            "sys.stdout.reconfigure(encoding='utf-8'); "
            "sys.stderr.reconfigure(encoding='utf-8'); "
            "value=sys.stdin.read();sys.stdout.write(value);sys.stderr.write(value);timer.cancel()"
        )
        if sys.platform == "win32":
            self.assertEqual(sys.flags.utf8_mode, 0, "test must exercise legacy mode")
        for streaming in (False, True):
            with self.subTest(streaming=streaming):
                result = helper.run_with_heartbeat(
                    [sys.executable, "-X", "utf8=0", "-c", child],
                    Path.cwd(), input_text=text, label="synthetic-utf8",
                    stream_output=streaming, stream_display=lambda *_: None,
                )
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout, text)
                self.assertEqual(result.stderr, text)

if __name__ == "__main__":
    unittest.main()
