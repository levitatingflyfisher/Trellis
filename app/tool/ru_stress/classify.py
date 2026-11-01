#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["scikit-learn", "numpy", "scipy"]
# ///
"""The tiny Russian stress model (plan step 8; owner, 17 Nov 2026).

For each vowel of a word it scores how likely that vowel is the stressed
one, from the letters around it and its place in the word (counted from
the end, and of how many). The word's stress is its best vowel, with that
vowel's share of the scores as how sure the model is. The scores are a
logistic regression; the model is a table of feature weights, small and
plain enough for the app to read without this library.

It learns only from printed marks: entries the scans agree on, and a
single book's printed mark (`scan-agree`, `scan-single`), and from rules.
`training_rows` refuses an AI-checked entry.

Usage: classify.py VOTES.tsv OUT.weights.tsv   (train on agree and single
rows and write the weights over 0.1)
"""

import math
import sys

from provenance import Entry, training_rows

VOWELS = set("аеёиоуыэюя")


def vowel_spots(word):
    return [i for i, c in enumerate(word) if c in VOWELS]


def features(word, at, k, n):
    """The features of the vowel at word[at], the k-th of n vowels."""
    w = "^" + word + "$"
    p = at + 1
    fe = n - 1 - k
    cap = min(n, 6)
    out = [f"fe={fe}", f"n={cap}", f"k={k}", f"fe{fe}n{cap}", f"v={w[p]}"]
    for a in range(-5, 6):
        for b in range(a + 1, min(a + 5, 6) + 1):
            lo, hi = p + a, p + b
            if 0 <= lo and hi <= len(w):
                out.append(f"{a}:{w[lo:hi]}")
    for size in range(1, 6):
        out.append(f"end{size}={w[-size - 1:]}|fe{fe}")
    for size in range(1, 4):
        out.append(f"beg{size}={w[:size + 1]}|k{k}")
    return out


class StressModel:
    def __init__(self, weights=None, bias=0.0):
        self.weights = weights or {}
        self.bias = bias

    def fit(self, entries, stress, C=1.0):
        """entries: Entry rows (checked by training_rows); stress: word ->
        0-based stressed vowel."""
        from sklearn.feature_extraction import DictVectorizer
        from sklearn.linear_model import LogisticRegression

        rows, y = [], []
        for e in training_rows(entries):
            spots = vowel_spots(e.word)
            n = len(spots)
            if n < 2:
                continue
            for k, at in enumerate(spots):
                rows.append(dict.fromkeys(features(e.word, at, k, n), 1))
                y.append(int(k == stress[e.word]))
        vec = DictVectorizer()
        X = vec.fit_transform(rows)
        lr = LogisticRegression(C=C, max_iter=2000).fit(X, y)
        names = vec.get_feature_names_out()
        self.weights = {str(names[j]): float(c)
                        for j, c in enumerate(lr.coef_[0]) if abs(c) > 1e-6}
        self.bias = float(lr.intercept_[0])
        return self

    def guess(self, word):
        """(0-based stressed vowel, how sure, 0 to 1), or None for a word
        of fewer than two vowels. A printed ё is the stress, surely."""
        spots = vowel_spots(word)
        n = len(spots)
        if n < 2:
            return None
        if "ё" in word:
            return [word[i] for i in spots].index("ё"), 1.0
        scores = [self.bias + sum(self.weights.get(f, 0.0)
                                  for f in features(word, at, k, n))
                  for k, at in enumerate(spots)]
        top = max(scores)
        exps = [math.exp(s - top) for s in scores]
        best = max(range(n), key=lambda k: scores[k])
        return best, exps[best] / sum(exps)

    def save(self, path, min_weight=0.0):
        """Writes the weights, leaving out those no larger than
        [min_weight]: at 0.1 the held-out score is unchanged (69.7% to
        69.6% on the words the lookups leave) and the file is a third."""
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"#bias\t{self.bias!r}\n")
            for name in sorted(self.weights):
                if abs(self.weights[name]) > min_weight:
                    f.write(f"{name}\t{self.weights[name]!r}\n")

    @classmethod
    def load(cls, path):
        weights, bias = {}, 0.0
        for line in open(path, encoding="utf-8"):
            name, value = line.rstrip("\n").split("\t")
            if name == "#bias":
                bias = float(value)
            else:
                weights[name] = float(value)
        return cls(weights, bias)


def load_rows(votes_path, statuses=("agree", "single")):
    """The printed-mark rows of a votes file as (entries, stress)."""
    kinds = {"agree": "scan-agree", "single": "scan-single"}
    entries, stress = [], {}
    for line in open(votes_path, encoding="utf-8"):
        word, vowel, status, _ = line.rstrip("\n").split("\t")
        if status in statuses:
            entries.append(Entry(word, kinds[status]))
            stress[word] = int(vowel)
    return entries, stress


def main(votes, out):
    StressModel().fit(*load_rows(votes)).save(out, min_weight=0.1)


if __name__ == "__main__":
    main(*sys.argv[1:3])
