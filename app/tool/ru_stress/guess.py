#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""The unknown-word guesser (plan step 8; owner, 17 Nov 2026: "the tiny
Russian stress model").

Russian stress follows the end of a word far more than its start: the
ending and the suffix before it decide most of it (-ость, -ание, -ировать,
-ческий). So the guesser counts, for every ending seen in training, where
the stress fell, counted in vowels from the end of the word. For a new
word it takes the longest ending it has seen often enough and says the
stress falls where it fell most often under that ending.

It learns only from entries the scans agree on (provenance `scan-agree`)
and from rules: `training_rows` refuses anything else, so an AI's answer
never reaches it.

Each guess comes with how sure it is: the share of training words under
that ending that had that stress, and how many there were. The table
uses a guess only above a threshold measured on held-out pages; below
it the word is left unmarked, which costs nothing in "confidently wrong".

Usage: guess.py VOTES.tsv WORD...    (prints word, vowel, share, count)
"""

import sys
from collections import Counter, defaultdict
from dataclasses import dataclass

from provenance import Entry, training_rows

VOWELS = set("аеёиоуыэюя")


def vowel_count(word):
    return sum(1 for c in word if c in VOWELS)


@dataclass(frozen=True)
class Guess:
    vowel: int  # 0-based index of the stressed vowel from the start
    share: float  # share of training words under the ending with this stress
    count: int  # how many training words were under the ending
    ending: str


class Guesser:
    def __init__(self, max_ending=7, min_count=3):
        self.max_ending = max_ending
        self.min_count = min_count
        self._by_ending = defaultdict(Counter)

    def fit(self, entries, stress):
        """entries: Entry rows (checked by training_rows); stress: word ->
        0-based stressed vowel."""
        for e in training_rows(entries):
            w = e.word
            n = vowel_count(w)
            if n < 2:
                continue
            from_end = n - 1 - stress[w]
            for k in range(1, min(self.max_ending, len(w)) + 1):
                self._by_ending[w[-k:]][from_end] += 1
        return self

    def guess(self, word):
        """The stress of [word], or None when no ending was seen often
        enough or the word has one vowel."""
        n = vowel_count(word)
        if n < 2:
            return None
        if "ё" in word:
            # A rule, always true: ё carries the stress.
            vowels = [c for c in word if c in VOWELS]
            return Guess(vowels.index("ё"), 1.0, 0, "ё")
        for k in range(min(self.max_ending, len(word)), 0, -1):
            counts = self._by_ending.get(word[-k:])
            if not counts:
                continue
            fitting = {d: c for d, c in counts.items() if d < n}
            total = sum(fitting.values())
            if total < self.min_count:
                continue
            from_end, c = max(fitting.items(), key=lambda kv: (kv[1], -kv[0]))
            return Guess(n - 1 - from_end, c / total, total, word[-k:])
        return None


def load_agree(votes_path):
    """The agree rows of a votes file as (entries, stress)."""
    entries, stress = [], {}
    for line in open(votes_path, encoding="utf-8"):
        word, vowel, status, _ = line.rstrip("\n").split("\t")
        if status == "agree":
            entries.append(Entry(word, "scan-agree"))
            stress[word] = int(vowel)
    return entries, stress


def main(votes, *words):
    g = Guesser().fit(*load_agree(votes))
    for w in words:
        r = g.guess(w.lower())
        print(w, *(r.vowel, f"{r.share:.2f}", r.count, r.ending) if r else ("-",), sep="\t")


if __name__ == "__main__":
    main(*sys.argv[1:])
