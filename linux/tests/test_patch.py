from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import rime_tts_common as c


class PatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "wubi_pinyin.custom.yaml"

    def tearDown(self):
        self.tmp.cleanup()

    def text(self) -> str:
        return self.path.read_text(encoding="utf-8")

    def test_creates_patch_section_for_new_file(self):
        self.assertTrue(c.patch_file(self.path))
        text = self.text()
        self.assertIn("patch:", text)
        self.assertIn(c.PATCH_LINE, text)
        self.assertIn(c.PATCH_BEGIN, text)
        self.assertIn(c.PATCH_END, text)

    def test_second_patch_is_a_noop(self):
        self.assertTrue(c.patch_file(self.path))
        before = self.text()
        self.assertFalse(c.patch_file(self.path))
        self.assertEqual(before, self.text())

    def test_inserts_under_existing_patch_map(self):
        self.path.write_text(
            "patch:\n"
            "  menu/page_size: 9\n"
            "  switches/@0/reset: 0\n",
            encoding="utf-8",
        )
        c.patch_file(self.path)
        text = self.text()
        lines = text.splitlines()
        self.assertEqual(lines[0], "patch:")
        self.assertTrue(any(c.PATCH_LINE in line for line in lines[1:4]))
        self.assertIn("menu/page_size: 9", text)
        self.assertIn("switches/@0/reset: 0", text)

    def test_upgrades_old_processors_append_block(self):
        self.path.write_text(
            "patch:\n"
            "  engine/processors/+:\n"
            "    - lua_processor@tts_reporter\n"
            "  menu/page_size: 9\n",
            encoding="utf-8",
        )
        self.assertTrue(c.patch_file(self.path))
        text = self.text()
        self.assertNotIn(c.PROCESSOR_LINE, text)
        self.assertNotIn("- lua_processor@tts_reporter", text)
        self.assertIn(c.PATCH_LINE, text)
        self.assertIn("menu/page_size: 9", text)

    def test_keeps_other_processors_in_old_block(self):
        self.path.write_text(
            "patch:\n"
            "  engine/processors/+:\n"
            "    - lua_processor@some_other_filter\n"
            "    - lua_processor@tts_reporter\n",
            encoding="utf-8",
        )
        c.patch_file(self.path)
        text = self.text()
        self.assertIn("lua_processor@some_other_filter", text)
        self.assertIn(c.PROCESSOR_LINE, text)
        self.assertIn(c.PATCH_LINE, text)

    def test_existing_before_zero_key_is_left_alone(self):
        self.path.write_text(
            "patch:\n"
            '  "engine/processors/@before 0": "lua_processor@tts_reporter"\n',
            encoding="utf-8",
        )
        self.assertFalse(c.patch_file(self.path))

    def test_unpatch_removes_every_trace(self):
        self.path.write_text(
            "patch:\n"
            "  menu/page_size: 9\n"
            "  engine/processors/+:\n"
            "    - lua_processor@tts_reporter\n",
            encoding="utf-8",
        )
        c.patch_file(self.path)
        self.assertTrue(c.unpatch_file(self.path))
        text = self.text()
        self.assertNotIn("tts_reporter", text)
        self.assertNotIn("rime-tts-readback", text)
        self.assertIn("menu/page_size: 9", text)
        self.assertFalse(c.unpatch_file(self.path))

    def test_unpatch_unknown_file_is_noop(self):
        self.path.write_text("patch:\n  menu/page_size: 9\n", encoding="utf-8")
        self.assertFalse(c.unpatch_file(self.path))


class LuaSourceTest(unittest.TestCase):
    def test_repo_lua_is_found(self):
        # HERE.parent/rime/rime.lua exists in the repository checkout.
        self.assertIsNotNone(c.rime_lua_source())


if __name__ == "__main__":
    unittest.main()
