from __future__ import annotations

import unittest

import rime_tts_text as text


class ReadableCharsTest(unittest.TestCase):
    def test_drops_punctuation_around_chinese(self):
        self.assertEqual(text.readable_chars("你好，世界。"), "你好世界")

    def test_keeps_one_space_between_ascii_words(self):
        self.assertEqual(text.readable_chars("hello   world"), "hello world")
        self.assertEqual(text.readable_chars("hello world"), "hello world")

    def test_no_space_between_chinese_and_ascii(self):
        self.assertEqual(text.readable_chars("你好 hello"), "你好hello")
        self.assertEqual(text.readable_chars("hello 世界"), "hello 世界")

    def test_ascii_switches_are_independent(self):
        self.assertEqual(text.readable_chars("abc123", read_digits=True, read_english=True), "abc123")
        self.assertEqual(text.readable_chars("abc123", read_digits=False, read_english=True), "abc")
        self.assertEqual(text.readable_chars("abc123", read_digits=True, read_english=False), "123")
        self.assertEqual(text.readable_chars("abc123", read_digits=False, read_english=False), "")

    def test_ascii_switch_does_not_drop_chinese(self):
        self.assertEqual(
            text.readable_chars("中文abc123", read_digits=False, read_english=False),
            "中文",
        )

    def test_whitespace_only(self):
        self.assertEqual(text.readable_chars("   \t\n"), "")


class BuildBodyTest(unittest.TestCase):
    def test_spells_out_ascii_runs(self):
        self.assertEqual(text.build_body("abc123"), "a b c 1 2 3")

    def test_keeps_chinese_continuous(self):
        self.assertEqual(text.build_body("你好世界"), "你好世界")

    def test_mixed_text(self):
        self.assertEqual(text.build_body("中文abc"), "中文a b c")

    def test_char_by_char_uses_fullwidth_comma(self):
        self.assertEqual(text.build_body("中文", char_by_char=True), "中，文")
        self.assertEqual(text.build_body("a1", char_by_char=True), "a，1")
        self.assertNotIn("<break", text.build_body("中文", char_by_char=True))

    def test_empty(self):
        self.assertEqual(text.build_body(""), "")


class AsciiOnlyTest(unittest.TestCase):
    def test_true_for_plain_ascii(self):
        self.assertTrue(text.ascii_only("abc 123"))

    def test_false_for_cjk_or_punctuation(self):
        self.assertFalse(text.ascii_only("abc，123"))
        self.assertFalse(text.ascii_only("中文"))
        self.assertFalse(text.ascii_only(""))
        self.assertFalse(text.ascii_only("abc\n"))


if __name__ == "__main__":
    unittest.main()
