# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest"]
# ///
"""The unknown-word guesser (plan step 8): stress by the word's ending,
learned only from entries the scans agree on.
Run: uv run --with pytest --with numpy pytest app/tool/ru_stress"""

import pytest

from guess import Guesser
from provenance import Entry, NotTrainable


def fit(stress, provenance="scan-agree", **kw):
    return Guesser(**kw).fit([Entry(w, provenance) for w in stress], stress)


def test_a_new_word_takes_the_stress_of_its_ending():
    # Stress counted from the end: the vowel before -ость.
    g = fit({"радость": 0, "гадость": 0, "слабость": 0, "храбрость": 0,
             "мудрость": 0, "молодость": 0}, min_count=3)
    r = g.guess("бодрость")
    assert r.vowel == 0 and r.ending.endswith("ость")
    assert g.guess("смелость").vowel == 0


def test_the_longest_ending_seen_often_enough_wins():
    stress = {"читать": 1, "писать": 1, "решать": 1,  # -ать: last vowel
              "плакать": 0, "прятать": 0, "прыгать": 0}  # -кать/-тать/-гать: first
    g = fit(stress, min_count=1)
    assert g.guess("макать").vowel == 0  # -кать seen once, after плакать
    g = fit(stress, min_count=4)
    assert g.guess("макать").vowel == 1  # only -ать is seen often enough


def test_a_guess_says_how_sure_it_is():
    g = fit({"рука": 1, "нога": 1, "мука": 0, "река": 1}, min_count=2)
    r = g.guess("щека")
    assert r.vowel == 1
    # -ека was seen once, under the bar; -ка three times, two of them so.
    assert r.share == pytest.approx(2 / 3) and r.count == 3


def test_no_guess_for_one_vowel_or_an_unseen_ending():
    g = fit({"рука": 1, "нога": 1, "река": 1}, min_count=2)
    assert g.guess("дом") is None
    assert g.guess("молоко") is None


def test_yo_is_always_stressed():
    g = fit({"рука": 1, "нога": 1, "река": 1})
    assert g.guess("ёлочка").vowel == 0


def test_a_stress_further_back_than_the_word_reaches_is_not_guessed():
    # Under -ость the stress most often falls three vowels from the end
    # here; a two-vowel word can't take that, so it gets the next.
    g = fit({"добросовестность": 2, "бессовестность": 1, "честность": 0},
            min_count=1)
    assert g.guess("местность").vowel == 0


def test_it_never_learns_from_an_ai_checked_entry():
    with pytest.raises(NotTrainable):
        fit({"рука": 1}, provenance="ai-checked")
