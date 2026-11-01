#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["scikit-learn", "numpy", "scipy"]
# ///
"""Build the stress table the Russian voice ships with.

Usage: build_table.py <votes.tsv> <forms.txt> <out.tsv> [--model-bar P]

Each word takes, in order:
  1. the vote of the printed books when they agree, or when only one has it;
  2. the majority of a disputed vote (one book over the others, or a 2:1 count);
  3. the tiny stress model's guess (classify.py, trained on rows 1's printed
     marks only), for every other word form Hunspell knows, when it is at
     least P sure (default 0: every word).
Words with fewer than two vowels need no stress and are left out. The file is
`word<TAB>vowelIndex`, ё written е, sorted by UTF-8 bytes, as
packages/russian_g2p's RussianStressTable reads it. Measured on the held-out
reader pages (REPORT.md, step 8): 92.5% right, about 5% really wrong."""
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from classify import StressModel, load_rows  # noqa: E402

VOWELS = set("аеёиоуыэюя")


def majority(evidence, ratio=2):
    """The vowel a disputed word's books lean to, or None (evaluate_model.py's rule)."""
    books, total = Counter(), Counter()
    for part in evidence.split():
        _, seen = part.split(":")
        per = Counter()
        for x in seen.split(","):
            v, c = x.split("x")
            per[int(v)] += int(c)
            total[int(v)] += int(c)
        top = per.most_common()
        if len(top) == 1 or top[0][1] > top[1][1]:
            books[top[0][0]] += 1
    b = books.most_common()
    if b and (len(b) == 1 or b[0][1] > b[1][1]):
        return b[0][0]
    t = total.most_common()
    if len(t) >= 2 and t[0][1] >= ratio * t[1][1]:
        return t[0][0]
    return None


def vowels(word):
    return sum(c in VOWELS for c in word)


def build(votes_path, forms_path, bar=0.0):
    table, counts = {}, Counter()
    for line in open(votes_path, encoding="utf-8"):
        w, v, tier, ev = line.rstrip("\n").split("\t")
        pick = int(v) if tier in ("agree", "single") and v else None
        if pick is None and tier == "disputed":
            pick = majority(ev)
        if pick is not None and vowels(w) >= 2:
            table[w] = pick
            counts[tier] += 1
    model = StressModel().fit(*load_rows(votes_path))
    for line in open(forms_path, encoding="utf-8"):
        w = line.strip().lower().replace("ё", "е")
        if not w or w in table or vowels(w) < 2 or not set(w) <= VOWELS | set("бвгджзйклмнпрстфхцчшщъь-"):
            continue
        k, p = model.guess(w)
        if p >= bar:
            table[w] = k
            counts["model"] += 1
    return table, counts


def main(argv):
    votes, forms, out = argv[:3]
    bar = float(argv[argv.index("--model-bar") + 1]) if "--model-bar" in argv else 0.0
    table, counts = build(votes, forms, bar)
    rows = sorted(table.items(), key=lambda kv: kv[0].encode("utf-8"))
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        for w, k in rows:
            f.write(f"{w}\t{k}\n")
    print(f"{len(rows)} words: " + ", ".join(f"{t} {n}" for t, n in counts.most_common()))


if __name__ == "__main__":
    main(sys.argv[1:])
