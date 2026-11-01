#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Vote on the stressed vowel of each modern word across dictionary scans.

Each sighting is (source, form with U+0301). The form is brought to modern
spelling (orthography.modernize) and kept only if Hunspell knows it. Words
are keyed lower case with ё written е, as Hunspell spells them.

- agree: two or more dictionaries, every sighting on the same vowel.
- single: one dictionary only, however often it says so (repeats in one
  book are not independent: an italic example or an archaic mark
  recurs); kept apart, never trained on.
- disputed: sightings on different vowels; no vowel is named. More scans
  may settle it; what stays disputed passes through unmarked.

A book in [dispute_only] (measured precision under 85%) can make a word
disputed but never counts toward agree, and alone names nothing.

Usage: vote.py HUNSPELL_FORMS SOURCE=forms.tsv... [--dispute-only dal] > votes.tsv
"""

import sys
from collections import defaultdict
from dataclasses import dataclass

from orthography import ACUTE, modernize

VOWELS = set("аеёиоуыэюя")


@dataclass
class Verdict:
    word: str
    vowel: int | None
    status: str
    counts: dict


def _vowel_index(form):
    """(index of the stressed vowel, vowel count) of a lower-case form."""
    idx, n = None, 0
    for ch in form:
        if ch == ACUTE and n:
            idx = n - 1
        elif ch in VOWELS:
            n += 1
    return idx, n


def vote(sightings, known, dispute_only=frozenset()):
    counts = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))
    for source, form in sightings:
        modern = modernize(form, known)
        if modern is None:
            continue
        modern = modern.lower()
        idx, n = _vowel_index(modern)
        if idx is None or n < 2:
            continue
        key = modern.replace(ACUTE, "").replace("ё", "е")
        counts[key][source][idx] += 1
    out = {}
    for key, by_source in counts.items():
        plain = {s: dict(c) for s, c in by_source.items()}
        trusted = {s: c for s, c in plain.items() if s not in dispute_only}
        if not trusted:
            continue
        vowels = {v for c in plain.values() for v in c}
        if len(vowels) > 1:
            out[key] = Verdict(key, None, "disputed", plain)
        else:
            out[key] = Verdict(key, vowels.pop(),
                               "agree" if len(trusted) >= 2 else "single", plain)
    return out


def load_known(path):
    return {l.strip().lower().replace("ё", "е") for l in open(path, encoding="utf-8") if l.strip()}


def main(argv):
    known = load_known(argv[0])
    sightings = []
    only = set()
    if "--dispute-only" in argv:
        i = argv.index("--dispute-only")
        only = set(argv[i + 1].split(","))
        argv = argv[:i] + argv[i + 2:]
    for arg in argv[1:]:
        source, path = arg.split("=", 1)
        for line in open(path, encoding="utf-8"):
            sightings.append((source, line.split("\t", 1)[0]))
    for v in sorted(vote(sightings, known, only).values(), key=lambda v: v.word):
        counts = " ".join(f"{s}:" + ",".join(f"{i}x{n}" for i, n in sorted(c.items()))
                          for s, c in sorted(v.counts.items()))
        print(f"{v.word}\t{'' if v.vowel is None else v.vowel}\t{v.status}\t{counts}")


if __name__ == "__main__":
    main(sys.argv[1:])
