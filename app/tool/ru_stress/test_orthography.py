# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest"]
# ///
"""Pre-reform Russian spelling to modern (the 1918 reform), keeping the
printed stress mark on its vowel. Run: uv run --with pytest pytest app/tool/ru_stress"""

from orthography import candidates, modernize, ACUTE

A = ACUTE


def test_letters_that_left_the_alphabet():
    assert candidates("хлѣбъ") == ["хлеб"]
    # -ія is also an adjective ending (синія), so the word list decides.
    assert candidates("Россія") == ["Россие", "Россия"]
    assert modernize("Россія", {"россия"}) == "Россия"
    assert candidates("ѳеатръ") == ["феатр"]
    assert candidates("мѵро") == ["миро"]


def test_final_hard_sign_goes_but_a_separating_one_stays():
    assert candidates("столъ") == ["стол"]
    assert candidates("объясненіе") == ["объяснение"]
    assert candidates("съѣздъ") == ["съезд"]


def test_the_stress_mark_stays_on_its_vowel():
    assert candidates(f"хлѣ{A}бъ") == [f"хле{A}б"]
    assert candidates(f"Заглуше{A}ніе") == [f"Заглуше{A}ние"]
    assert candidates(f"до{A}браго") == [f"до{A}брого", f"до{A}браго"]


def test_adjective_endings_offer_the_modern_form_first():
    assert candidates("добраго") == ["доброго", "добраго"]
    assert candidates("синяго") == ["синего", "синяго"]
    assert candidates("добрыя") == ["добрые", "добрыя"]
    assert candidates("синія") == ["синие", "синия"]


def test_prefix_z_before_a_voiceless_consonant():
    assert candidates("разсказъ") == ["рассказ", "разсказ"]
    assert candidates("безполезный") == ["бесполезный", "безполезный"]
    assert candidates("разбить") == ["разбить"]


def test_pronouns_with_their_own_forms():
    assert candidates("онѣ") == ["они", "оне"]
    assert candidates("ея") == ["её", "ея"]


def test_the_lexicon_picks_the_candidate():
    known = {"благо", "доброго", "рассказ"}
    assert modernize("благо", known) == "благо"
    assert modernize("добраго", known) == "доброго"
    assert modernize("разсказъ", known) == "рассказ"
    assert modernize(f"разска{A}зъ", known) == f"расска{A}з"
    assert modernize("невѣдомое", known) is None


def test_capitals_and_case_are_kept():
    assert candidates("ѢДА") == ["ЕДА"]
    assert candidates("Іисусъ") == ["Иисус"]
