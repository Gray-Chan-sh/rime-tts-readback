from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import rime_tts_common as c
import rime_tts_control as ctl


class AutostartTest(unittest.TestCase):
    def test_appimage_restarts_itself_in_reader_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rime-tts-readback.desktop"
            with mock.patch.object(c, "AUTOSTART_FILE", path):
                with mock.patch.dict(
                    os.environ, {"APPIMAGE": "/tmp/Rime TTS Readback.AppImage"}
                ):
                    self.assertTrue(ctl.set_autostart(True))
                    text = path.read_text(encoding="utf-8")

                self.assertIn(
                    'Exec="/tmp/Rime TTS Readback.AppImage" --reader-daemon', text
                )
                self.assertTrue(ctl.set_autostart(False))
                self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
