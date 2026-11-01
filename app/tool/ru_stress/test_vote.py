# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest"]
# ///
"""Voting across dictionaries on the stressed vowel of each modern word.
Run: uv run --with pytest pytest app/tool/ru_stress"""

from vote import vote, Verdict, ACUTE

A = ACUTE
KNOWN = {"хлеб", "корова", "замок", "дорога", "доброго", "лес"}


def test_two_sightings_on_one_vowel_agree():
    got = vote([("pavl", f"коро{A}ва"), ("akad", f"Коро{A}ва")], KNOWN)
    assert got == {"корова": Verdict("корова", 1, "agree", {"pavl": {1: 1}, "akad": {1: 1}})}


def test_one_dictionary_seen_twice_is_still_one_source():
    # Repeats in one book are not independent: the same italic example or
    # archaic mark recurs (14 Nov: до́стает, пробы́ from the Academy alone).
    got = vote([("pavl", f"доро{A}га"), ("pavl", f"доро{A}га")], KNOWN)
    assert got["дорога"].status == "single"
    assert got["дорога"].vowel == 1


def test_a_single_sighting_is_kept_apart():
    got = vote([("akad", f"доро{A}га")], KNOWN)
    assert got["дорога"].status == "single"
    assert got["дорога"].vowel == 1


def test_disagreement_is_disputed_and_names_no_vowel():
    got = vote([("pavl", f"за{A}мок"), ("akad", f"замо{A}к")], KNOWN)
    assert got["замок"].status == "disputed"
    assert got["замок"].vowel is None
    assert got["замок"].counts == {"pavl": {0: 1}, "akad": {1: 1}}


def test_pre_reform_spelling_is_modernized_before_the_vote():
    got = vote([("akad", f"до{A}браго"), ("pavl", f"до{A}брого")], KNOWN)
    assert got["доброго"].status == "agree" and got["доброго"].vowel == 0


def test_words_hunspell_does_not_know_are_dropped():
    assert vote([("pavl", f"пла{A}чивать"), ("pavl", f"пла{A}чивать")], KNOWN) == {}


def test_one_vowel_words_need_no_vote():
    assert vote([("pavl", f"хлѣ{A}бъ"), ("akad", f"ле{A}съ")], KNOWN) == {}


def test_words_are_keyed_as_hunspell_spells_them():
    # Lower case, ё written е, so ёлка and елка are one word.
    got = vote([("pavl", f"ё{A}лка"), ("akad", f"Е{A}лка")], {"елка"})
    assert got["елка"].vowel == 0 and got["елка"].status == "agree"


def test_a_dispute_only_book_can_block_but_never_confirm():
    # A book whose measured precision is under 85% (Dal: 65%, check set 3)
    # may say a word is disputed, never that it agrees.
    only = {"dal"}
    got = vote([("pavl", f"доро{A}га"), ("dal", f"доро{A}га")], KNOWN,
               dispute_only=only)
    assert got["дорога"].status == "single"
    got = vote([("pavl", f"доро{A}га"), ("dal", f"до{A}рога")], KNOWN,
               dispute_only=only)
    assert got["дорога"].status == "disputed"
    got = vote([("dal", f"доро{A}га"), ("dal", f"доро{A}га")], KNOWN,
               dispute_only=only)
    assert "дорога" not in got, "a dispute-only book alone names nothing"
