#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "pillow"]
# ///
"""Keeps the upright words of an extract.py table, dropping italic ones.

The dictionaries print their examples in italic, with no stress marks,
and the accent finder was measured only on upright words (the check sets
dropped italics by this same test: on the first set it caught all 35
italic crops and wrongly dropped 4 of 219 upright ones). A claim on an
italic word is noise, and it repeats, so two of them can falsely agree.

Usage: upright.py FORMS.tsv SCANS_DIR > upright.tsv
(SCANS_DIR holds <page>.jpg; the page column names the file.)
"""

import sys
from pathlib import Path

import numpy as np

MAX_SHEAR = 0.15


def _otsu(g):
    hist = np.bincount(g.ravel(), minlength=256).astype(float)
    total = hist.sum()
    if total == 0:
        return 128
    sum_all = float(np.dot(np.arange(256), hist))
    w0 = s0 = 0.0
    best, t_best = -1.0, 128
    for t in range(256):
        w0 += hist[t]
        if w0 == 0 or w0 == total:
            continue
        s0 += t * hist[t]
        m0, m1 = s0 / w0, (sum_all - s0) / (total - w0)
        v = w0 * (total - w0) * (m0 - m1) ** 2
        if v > best:
            best, t_best = v, t
    return t_best


def shear(g):
    """The right-leaning shear that makes the word's stems most upright."""
    ink = g < _otsu(g)
    h = ink.shape[0]
    ys, xs = np.nonzero(ink)
    if len(xs) == 0:
        return 0.0
    best, bs = -1.0, 0.0
    for s in np.arange(-0.1, 0.45, 0.05):
        xx = np.round(xs - s * (h - 1 - ys)).astype(int)
        v = float((np.bincount(xx - xx.min()).astype(float) ** 2).sum())
        if v > best:
            best, bs = v, float(s)
    return round(bs, 2)


def is_italic(g):
    return shear(g) >= MAX_SHEAR


def main(forms, scans):
    from PIL import Image

    cache = {}
    for line in open(forms, encoding="utf-8"):
        cols = line.rstrip("\n").split("\t")
        page, x0, y0, x1, y1 = cols[1], *map(int, (cols[2], cols[3], cols[5], cols[6]))
        if page not in cache:
            cache.clear()  # pages arrive in order; keep one in memory
            cache[page] = np.asarray(
                Image.open(Path(scans) / f"{page}.jpg").convert("L"))
        g = cache[page][y0:y1, x0:x1]
        if g.size and not is_italic(g):
            sys.stdout.write(line)


if __name__ == "__main__":
    main(*sys.argv[1:3])
