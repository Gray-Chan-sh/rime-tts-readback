from __future__ import annotations

import unittest

from rime_tts_hotkey import CONTROL, MOD1, MOD4, SHIFT, parse_hotkey


class ParseHotKeyTest(unittest.TestCase):
    def test_ctrl_alt_r(self):
        self.assertEqual(parse_hotkey("ctrl+alt+r"), (CONTROL | MOD1, "r"))

    def test_aliases_and_case(self):
        self.assertEqual(parse_hotkey("Control+Option+R"), (CONTROL | MOD1, "R"))
        self.assertEqual(parse_hotkey("win+space"), (MOD4, "space"))
        self.assertEqual(parse_hotkey("super+shift+f1"), (MOD4 | SHIFT, "F1"))

    def test_requires_modifier_and_key(self):
        self.assertIsNone(parse_hotkey(""))
        self.assertIsNone(parse_hotkey("   "))
        self.assertIsNone(parse_hotkey("r"))
        self.assertIsNone(parse_hotkey("ctrl"))
        self.assertIsNone(parse_hotkey("ctrl+"))


if __name__ == "__main__":
    unittest.main()
