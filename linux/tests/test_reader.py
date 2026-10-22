from __future__ import annotations

import unittest

import rime_tts_reader as reader


def cfg(mode: str, apps):
    return {"AppFilterMode": mode, "AppFilterList": apps}


class AppFilterTest(unittest.TestCase):
    def test_all_reads_everything(self):
        self.assertTrue(reader.app_allowed(("firefox", "Mozilla Firefox"), cfg("all", [])))

    def test_only(self):
        rule = cfg("only", ["firefox", "code"])
        self.assertTrue(reader.app_allowed(("firefox", "Mozilla Firefox"), rule))
        self.assertTrue(reader.app_allowed(("code", "Visual Studio Code"), rule))
        self.assertFalse(reader.app_allowed(("kitty", "~"), rule))

    def test_except(self):
        rule = cfg("except", ["firefox"])
        self.assertFalse(reader.app_allowed(("firefox", "Mozilla Firefox"), rule))
        self.assertTrue(reader.app_allowed(("kitty", "~"), rule))

    def test_matching_is_case_insensitive(self):
        self.assertTrue(reader.app_allowed(("Firefox", "Mozilla Firefox"), cfg("only", ["firefox"])))

    def test_empty_list_reads_everything(self):
        self.assertTrue(reader.app_allowed(("kitty", "~"), cfg("only", [])))
        self.assertTrue(reader.app_allowed(("kitty", "~"), cfg("except", [])))

    def test_unknown_foreground_is_not_filtered(self):
        # Wayland / missing xdotool: never silence the reader by accident.
        self.assertTrue(reader.app_allowed(("", ""), cfg("only", ["firefox"])))
        self.assertTrue(reader.app_allowed(("", ""), cfg("except", ["firefox"])))

    def test_exe_suffix_is_accepted_for_compatibility(self):
        self.assertTrue(reader.app_allowed(("firefox", "Firefox"), cfg("only", ["firefox.exe"])))


class MergedConfigTest(unittest.TestCase):
    def test_cli_overrides_beat_file_defaults(self):
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            cfg = reader.merged_config(path, {"Rate": 99, "ReadDigits": False})
        self.assertEqual(cfg["Rate"], 10)
        self.assertFalse(cfg["ReadDigits"])
        self.assertTrue(cfg["ReadEnglish"])


if __name__ == "__main__":
    unittest.main()
