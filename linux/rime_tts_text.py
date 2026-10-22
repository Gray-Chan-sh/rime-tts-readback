#!/usr/bin/env python3
"""Text normalisation shared by the Linux reader, panel and tests.

The rules mirror the macOS watcher (RimeTtsWatcher.swift):
  * drop punctuation and whitespace around Chinese, but keep one word break
    between ASCII letters ("hello world")
  * optionally filter ASCII digits / ASCII letters with two independent switches
  * spell ASCII runs out ("abc123" -> "a b c 1 2 3") so the voice does not turn
    them into a word or a number
  * per-character mode uses a full-width comma, never SSML <break>
"""

from __future__ import annotations


def is_ascii_alnum(ch: str) -> bool:
    return len(ch) == 1 and ch.isascii() and ch.isalnum()


def readable_chars(text: str, read_digits: bool = True, read_english: bool = True) -> str:
    out = ""
    for ch in text:
        if ch.isspace():
            # One word break between ASCII letters; no spaces around Chinese.
            if out and out[-1] != " " and out[-1].isascii() and out[-1].isalpha():
                out += " "
            continue
        if not ch.isalnum():
            continue
        if ch.isascii():
            if ch.isalpha() and not read_english:
                continue
            if ch.isdigit() and not read_digits:
                continue
        out += ch
    return out.strip()


def build_body(readable: str, char_by_char: bool = False) -> str:
    if char_by_char:
        return "\uff0c".join(readable)
    out = []
    prev_ascii = False
    for ch in readable:
        ascii_alnum = is_ascii_alnum(ch)
        if ascii_alnum and prev_ascii:
            out.append(" ")
        out.append(ch)
        prev_ascii = ascii_alnum
    return "".join(out)


def ascii_only(text: str) -> bool:
    if not text:
        return False
    for ch in text:
        if not ch.isascii():
            return False
        if not (ch.isalnum() or ch == " "):
            return False
    return True
