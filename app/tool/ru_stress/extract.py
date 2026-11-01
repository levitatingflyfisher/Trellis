#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stressed words out of the accent finder's page output (JSON lines, one
word each, in the OCR's reading order).

Every marked word counts, not only headwords: the dictionaries mark the
forms inside an entry too. A word split at a line end is joined with the
first word of the next line. OCR junk (Latin words, stray symbols) is
dropped; Hunspell drops the rest later.

Usage: extract.py RESULTS.jsonl [--min-confidence 0.6] [--min-density D] > forms.tsv

--min-density keeps only words as inked as the bold entry words the finder
was measured on (check sets: 0.50 for Pavlovsky, 0.39 for the Academy).
Running text carries no printed marks, so a claim there is noise.
Output columns: form (with U+0301), page, x0, y0, confidence, x1, y1.
"""

import json
import sys
from dataclasses import dataclass

ACUTE = "́"
VOWELS = set("аеёиіоуыэюяѣѵАЕЁИІОУЫЭЮЯѢѴ")
LETTERS = set("абвгдеёжзийклмнопрстуфхцчшщъыьэюяіѣѳѵ")
LETTERS |= {c.upper() for c in LETTERS}
LOOK_ALIKE = dict(zip("aeoypcxAEOPCXBHKMTiI", "аеоурсхАЕОРСХВНКМТіІ"))
EDGE_PUNCT = ".,;:!?()[]«»\"'„“”-–—*"


@dataclass(frozen=True)
class Stressed:
    form: str
    page: str
    x0: int
    y0: int
    confidence: float
    x1: int = 0
    y1: int = 0


def clean(raw, stress_char):
    """The word with U+0301 after its marked letter, or None when the word
    is not plain Cyrillic or the mark is not on a vowel."""
    chars = [LOOK_ALIKE.get(c, c) for c in raw]
    # An ending printed alone ("-у́ша") is not a word: without its hyphen
    # it would pose as a short real one.
    lead = 0
    while lead < len(chars) and chars[lead] in "«(\"[„“":
        lead += 1
    if lead < len(chars) and chars[lead] in "-–—":
        return None
    start, end = 0, len(chars)
    while start < end and chars[start] in EDGE_PUNCT:
        start += 1
    while end > start and chars[end - 1] in EDGE_PUNCT:
        end -= 1
    body = chars[start:end]
    if not body or not all(c in LETTERS or c == "-" for c in body):
        return None
    i = stress_char - start
    if not 0 <= i < len(body) or body[i] not in VOWELS:
        return None
    return "".join(body[: i + 1]) + ACUTE + "".join(body[i + 1:])


def _line_break(a, b):
    """True when word b starts a new line after word a."""
    return b["bbox"][0] < a["bbox"][0] and b["bbox"][1] > (a["bbox"][1] + a["bbox"][3]) / 2


def stressed_words(words, min_confidence=0.0, min_density=0.0):
    out = []
    i = 0
    while i < len(words):
        a = words[i]
        nxt = words[i + 1] if i + 1 < len(words) else None
        raw, stress, conf = a["word"], a.get("stress_char"), a.get("confidence", 0.0)
        if (nxt is not None and raw.endswith("-") and len(raw.rstrip("-")) > 0
                and _line_break(a, nxt)):
            head = raw.rstrip("-")
            raw = head + nxt["word"]
            b_stress = nxt.get("stress_char")
            if b_stress is not None and (stress is None or nxt.get("confidence", 0.0) > conf):
                stress, conf = len(head) + b_stress, nxt.get("confidence", 0.0)
            i += 1
        i += 1
        if stress is None or conf < min_confidence or conf <= 0:
            continue
        if a.get("density", 1.0) < min_density:
            continue
        form = clean(raw, stress)
        if form:
            b = a["bbox"]
            # A word joined across a line end keeps its first part's box.
            out.append(Stressed(form, a["page"], b[0], b[1], conf, b[2], b[3]))
    return out


def main(argv):
    path = argv[0]
    def opt(name):
        return float(argv[argv.index(name) + 1]) if name in argv else 0.0
    minc, mind = opt("--min-confidence"), opt("--min-density")
    pages = {}
    for line in open(path, encoding="utf-8"):
        rec = json.loads(line)
        pages.setdefault(rec["page"], []).append(rec)
    for words in pages.values():
        for s in stressed_words(words, minc, mind):
            print(f"{s.form}\t{s.page}\t{s.x0}\t{s.y0}\t{s.confidence}\t{s.x1}\t{s.y1}")


if __name__ == "__main__":
    main(sys.argv[1:])
