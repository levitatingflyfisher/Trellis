# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest", "numpy"]
# ///
"""Italic words carry no printed stress marks (the dictionaries' examples),
and the finder was measured on upright words only, so only upright words
are taken. Run: uv run --with pytest --with numpy pytest app/tool/ru_stress"""

import numpy as np

from upright import shear, is_italic


def strokes(slant):
    """A scan-like crop: noisy light paper, three noisy dark stems leaning
    right by [slant] (a scan has many grey levels, as the threshold
    expects)."""
    rng = np.random.default_rng(7)
    g = rng.integers(200, 256, size=(40, 60)).astype(np.uint8)
    for x0 in (10, 25, 40):
        for y in range(5, 35):
            x = int(round(x0 + slant * (34 - y)))
            g[y, x:x + 3] = rng.integers(0, 60, size=3)
    return g


def test_upright_stems_need_no_shear():
    assert shear(strokes(0.0)) == 0.0
    assert not is_italic(strokes(0.0))


def test_slanted_stems_are_italic():
    assert shear(strokes(0.25)) >= 0.15
    assert is_italic(strokes(0.25))


def test_a_blank_crop_is_not_italic():
    assert not is_italic(np.full((10, 10), 255, dtype=np.uint8))
