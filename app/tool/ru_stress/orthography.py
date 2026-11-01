#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Pre-reform Russian spelling to modern, the 1918 reform's rules written
from the decree's facts, keeping a printed stress mark (U+0301 after its
vowel) on its vowel. Some rules depend on the word (благо keeps -аго;
добраго becomes доброго), so a word gets candidates, modern first, and a
modern word list picks.

    ./orthography.py хлѣбъ разсказъ    # prints the candidates
"""

import sys

ACUTE = "́"

_LETTERS = {"ѣ": "е", "Ѣ": "Е", "і": "и", "І": "И", "ѳ": "ф", "Ѳ": "Ф",
            "ѵ": "и", "Ѵ": "И"}
_VOICELESS = set("кпстфхцчшщКПСТФХЦЧШЩ")
_PREFIXES = ("через", "чрез", "раз", "роз", "воз", "без", "из", "низ")
# Words of their own: the modern form, then the old one as written.
_PRONOUNS = {"онѣ": "они", "однѣ": "одни", "однѣхъ": "одних",
             "однѣми": "одними", "ея": "её"}


def _split(word):
    """The letters of [word] and the stress mark after each, if any."""
    letters, marks = [], []
    for ch in word:
        if ch == ACUTE and letters:
            marks[-1] = True
        else:
            letters.append(ch)
            marks.append(False)
    return letters, marks


def _join(letters, marks):
    return "".join(c + (ACUTE if m else "") for c, m in zip(letters, marks))


def _same_case(src, dst):
    return dst.upper() if src.isupper() and len(src) > 1 else (
        dst[0].upper() + dst[1:] if src[:1].isupper() else dst)


def candidates(word):
    """[word] in modern spelling: the forms it may have, modern first."""
    letters, marks = _split(word)
    # The final hard sign goes (it carries no sound and no mark).
    if len(letters) > 1 and letters[-1] in "ъЪ":
        letters, marks = letters[:-1], marks[:-1]
    plain = "".join(letters)
    if plain.lower() in _PRONOUNS:
        modern = _same_case(plain, _PRONOUNS[plain.lower()])
        old = "".join(_LETTERS.get(c, c) for c in plain)
        out = [modern, old]
        if any(marks):
            out = [_join(list(f), marks) if len(f) == len(marks) else f
                   for f in out]
        return list(dict.fromkeys(out))
    letters = [_LETTERS.get(c, c) for c in letters]
    forms = [letters]
    low = "".join(letters).lower()
    # Adjective endings: -аго/-яго to -ого/-его, -ыя/-ія to -ые/-ие.
    for old, new in (("аго", "ого"), ("яго", "его"), ("ыя", "ые"),
                     ("ия", "ие")):
        if low.endswith(old) and len(low) > len(old) + 1:
            cut = len(letters) - len(old)
            alt = letters[:cut] + [_same_case(letters[cut + i], new[i])
                                   for i in range(len(old))]
            forms = [alt, letters]
            break
    # A prefix's з before a voiceless consonant became с.
    for p in _PREFIXES:
        n = len(p)
        if (low.startswith(p) and len(low) > n
                and letters[n] in _VOICELESS):
            out = []
            for f in forms:
                g = list(f)
                g[n - 1] = _same_case(g[n - 1], "с")
                out.append(g)
            forms = out + forms
            break
    return list(dict.fromkeys(_join(f, marks) for f in forms))


def _key(form):
    return form.replace(ACUTE, "").replace("ё", "е").replace("Ё", "Е").lower()


def modernize(word, known):
    """The first candidate of [word] that [known] (modern words, lower
    case, ё written е) holds, with its stress mark; None when none is."""
    for c in candidates(word):
        if _key(c) in known:
            return c
    return None


if __name__ == "__main__":
    for w in sys.argv[1:]:
        print(w, " ".join(candidates(w)))
