#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Stress classes (plan step 6): a stress the scans agree on, carried to
the other forms of the same Hunspell entry when it sits in the part every
form shares.

For an entry (stem and its suffix flags), each form is the stem with its
rule's [strip] cut and [add] put on. A stressed vowel inside the cut stem
of a form lies in the part the form shares with the stem. When every
agreed form of the entry has its stress there, on the same vowel, each
other form whose cut stem holds that vowel takes it. A stress on an
ending (рука́, ру́ку) moves, so nothing is carried; agreed forms that
disagree carry nothing; a form two entries give different stresses is
left out; an agreed word is never changed.

The rows this makes are lookup rows ('class' provenance), scored on the
held-out reader pages before use.

Usage: classes.py RU_RU.dic RU_RU.aff VOTES.tsv [MIN_KNOWN] > classes.tsv
(MIN_KNOWN: how many agreed forms must keep the stress on the stem.)
"""

import re
import sys
from collections import defaultdict
from dataclasses import dataclass

VOWELS = set("аеёиоуыэюя")


@dataclass(frozen=True)
class Rule:
    strip: str
    add: str
    cond: str = ""

    def applies(self, stem):
        if self.strip and not stem.endswith(self.strip):
            return False
        return not self.cond or re.search(f"(?:{self.cond})$", stem) is not None


def _vowels(s):
    return sum(1 for c in s if c in VOWELS)


def _forms(stem, flags, rules):
    """(form, vowels in the shared part) for the stem and each rule."""
    out = [(stem, _vowels(stem))]
    for f in flags:
        for r in rules.get(f, []):
            if r.applies(stem):
                kept = stem[: len(stem) - len(r.strip)]
                out.append((kept + r.add, _vowels(kept)))
    return out


def carry(entries, rules, agree, min_known=1):
    got = defaultdict(set)
    for stem, flags in entries:
        forms = _forms(stem, flags, rules)
        known = [(agree[f], shared) for f, shared in forms if f in agree]
        if len(known) < min_known:
            continue
        stems = {i for i, shared in known if i < shared}
        if len(stems) != 1 or any(i >= shared for i, shared in known):
            continue
        i = stems.pop()
        for f, shared in forms:
            if f not in agree and i < shared:
                got[f].add(i)
    return {f: next(iter(s)) for f, s in got.items() if len(s) == 1}


def load_hunspell(dic, aff):
    rules = defaultdict(list)
    for line in open(aff, encoding="utf-8"):
        p = line.split()
        if len(p) >= 5 and p[0] == "SFX":
            _, flag, strip, add, cond = p[:5]
            rules[flag].append(Rule("" if strip == "0" else strip,
                                    "" if add == "0" else add.split("/")[0],
                                    "" if cond == "." else cond))
    entries = []
    for line in open(dic, encoding="utf-8").read().splitlines()[1:]:
        w, _, fl = line.strip().partition("/")
        if w:
            entries.append((w.lower().replace("ё", "е"), fl))
    return entries, rules


def main(dic, aff, votes, min_known="1"):
    entries, rules = load_hunspell(dic, aff)
    agree = {}
    for line in open(votes, encoding="utf-8"):
        word, vowel, status, _ = line.rstrip("\n").split("\t")
        if status == "agree":
            agree[word] = int(vowel)
    for f, i in sorted(carry(entries, rules, agree, int(min_known)).items()):
        print(f"{f}\t{i}\tclass")


if __name__ == "__main__":
    main(*sys.argv[1:5])
