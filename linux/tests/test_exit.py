from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest import mock

import rime_tts_common as c
import rime_tts_control as ctl


class ReadbackActiveTest(unittest.TestCase):
    def test_only_when_reader_runs_and_is_not_muted(self):
        with tempfile.TemporaryDirectory() as tmp:
            off_file = Path(tmp) / "tts_off"
            with mock.patch.object(c, "OFF_FILE", off_file):
                with mock.patch.object(c, "reader_running", return_value=True):
                    self.assertTrue(ctl.readback_active())

                    off_file.write_text("1", encoding="utf-8")
                    self.assertFalse(ctl.readback_active())

                    off_file.unlink()
                    with mock.patch.object(c, "reader_running", return_value=False):
                        self.assertFalse(ctl.readback_active())


if __name__ == "__main__":
    unittest.main()
