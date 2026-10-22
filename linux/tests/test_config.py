from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import rime_tts_common as c


class ConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "config.json"

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, obj) -> None:
        self.path.write_text(json.dumps(obj), encoding="utf-8")

    def test_defaults_when_missing(self):
        cfg = c.load_config(self.path)
        self.assertEqual(cfg, c.DEFAULT_CONFIG)
        self.assertTrue(cfg["ReadDigits"])
        self.assertTrue(cfg["ReadEnglish"])
        self.assertEqual(cfg["AppFilterMode"], "all")

    def test_legacy_include_ascii_false(self):
        self.write({"IncludeAscii": False})
        cfg = c.load_config(self.path)
        self.assertFalse(cfg["ReadDigits"])
        self.assertFalse(cfg["ReadEnglish"])

    def test_legacy_include_ascii_true(self):
        self.write({"IncludeAscii": True})
        cfg = c.load_config(self.path)
        self.assertTrue(cfg["ReadDigits"])
        self.assertTrue(cfg["ReadEnglish"])

    def test_explicit_keys_beat_legacy(self):
        self.write({"IncludeAscii": False, "ReadDigits": True})
        cfg = c.load_config(self.path)
        self.assertTrue(cfg["ReadDigits"])
        self.assertFalse(cfg["ReadEnglish"])

    def test_hotkey_bool_is_migrated(self):
        self.write({"HotKey": True})
        self.assertEqual(c.load_config(self.path)["HotKey"], "ctrl+alt+r")
        self.write({"HotKey": False})
        self.assertEqual(c.load_config(self.path)["HotKey"], "")

    def test_clamping(self):
        self.write({"Rate": 99, "Volume": -5, "IdleMs": -1, "MaxWaitMs": 999999})
        cfg = c.load_config(self.path)
        self.assertEqual(cfg["Rate"], 10)
        self.assertEqual(cfg["Volume"], 0)
        self.assertEqual(cfg["IdleMs"], 0)
        self.assertEqual(cfg["MaxWaitMs"], 10000)

    def test_save_roundtrip_and_legacy_key(self):
        cfg = dict(c.DEFAULT_CONFIG)
        cfg.update({"ReadDigits": True, "ReadEnglish": False, "Voice": "zh", "Rate": 3})
        c.save_config(cfg, self.path)
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertFalse(raw["IncludeAscii"])
        self.assertEqual(raw["ReadDigits"], True)
        self.assertEqual(raw["ReadEnglish"], False)
        loaded = c.load_config(self.path)
        self.assertEqual(loaded["Rate"], 3)
        self.assertEqual(loaded["Voice"], "zh")

    def test_save_preserves_unknown_keys(self):
        self.write({"SomethingNew": {"a": 1}})
        c.save_config(dict(c.DEFAULT_CONFIG), self.path)
        raw = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(raw["SomethingNew"], {"a": 1})

    def test_broken_json_falls_back(self):
        self.path.write_text("{not json", encoding="utf-8")
        self.assertEqual(c.load_config(self.path), c.DEFAULT_CONFIG)


class QueueTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_numeric_order_not_lexicographic(self):
        for name in ("100_0.txt", "9_0.txt", "10_1.txt", "10_0.txt"):
            (self.dir / name).write_text(name, encoding="utf-8")
        (self.dir / "notes.md").write_text("ignored", encoding="utf-8")
        names = [p.name for p in c.queue_files(self.dir)]
        self.assertEqual(names, ["9_0.txt", "10_0.txt", "10_1.txt", "100_0.txt"])

    def test_count_and_clear(self):
        (self.dir / "1_0.txt").write_text("a", encoding="utf-8")
        (self.dir / "2_0.txt.tmp").write_text("b", encoding="utf-8")
        (self.dir / "keep.md").write_text("c", encoding="utf-8")
        self.assertEqual(c.queue_count(self.dir), 1)
        self.assertEqual(c.clear_queue(self.dir), 2)
        self.assertEqual(c.queue_count(self.dir), 0)
        self.assertTrue((self.dir / "keep.md").exists())

    def test_missing_dir_is_empty(self):
        self.assertEqual(c.queue_files(self.dir / "nope"), [])
        self.assertEqual(c.clear_queue(self.dir / "nope"), 0)


if __name__ == "__main__":
    unittest.main()
