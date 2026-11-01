# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest", "scikit-learn"]
# ///
"""The tiny stress model (plan step 8): a per-vowel score from the letters
around each vowel, learned only from printed marks.
Run: uv run --with pytest --with numpy --with scikit-learn pytest app/tool/ru_stress"""

import pytest

from classify import StressModel
from provenance import Entry, NotTrainable

# Stem-stressed -ость nouns and end-stressed -ать verbs.
STRESS = {"радость": 0, "гадость": 0, "слабость": 0, "храбрость": 0,
          "мудрость": 0, "смелость": 0, "верность": 0, "гордость": 0,
          "читать": 1, "писать": 1, "решать": 1, "играть": 1,
          "бежать": 1, "лежать": 1, "кричать": 1, "молчать": 1}


def model(stress=STRESS, kind="scan-agree"):
    return StressModel().fit([Entry(w, kind) for w in stress], stress, C=10)


def test_it_learns_where_an_ending_puts_the_stress():
    m = model()
    assert m.guess("бодрость")[0] == 0
    assert m.guess("стучать")[0] == 1


def test_a_guess_says_how_sure_it_is():
    vowel, sure = model().guess("бодрость")
    assert 0.5 < sure <= 1.0


def test_one_vowel_is_no_guess_and_yo_is_the_stress():
    m = model()
    assert m.guess("дом") is None
    assert m.guess("ёлочка") == (0, 1.0)


def test_a_single_books_printed_mark_may_train_it():
    assert model(kind="scan-single").guess("бодрость")[0] == 0


def test_it_never_learns_from_an_ai_checked_entry():
    with pytest.raises(NotTrainable):
        model(kind="ai-checked")


def test_the_saved_weights_give_the_same_guesses(tmp_path):
    m = model()
    path = tmp_path / "w.tsv"
    m.save(path)
    again = StressModel.load(path)
    for w in ("бодрость", "стучать", "кротость", "рычать"):
        assert again.guess(w) == pytest.approx(m.guess(w))


def test_small_weights_can_be_left_out_of_the_file(tmp_path):
    m = model()
    path = tmp_path / "w.tsv"
    m.save(path, min_weight=0.5)
    kept = StressModel.load(path).weights
    assert 0 < len(kept) < len(m.weights)
    assert all(abs(v) > 0.5 for v in kept.values())
