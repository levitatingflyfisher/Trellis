# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest"]
# ///
"""Stressed words out of the accent finder's page output: rejoin words split
at a line end, keep the mark on its letter, drop OCR junk.
Run: uv run --with pytest pytest app/tool/ru_stress"""

from extract import stressed_words, clean, ACUTE

A = ACUTE


def w(word, x, y, stress=None, conf=0.0, page="p1"):
    return {"page": page, "word": word, "bbox": [x, y, x + 40 * len(word), y + 50],
            "stress_char": stress, "confidence": conf}


def test_a_marked_word_comes_out_with_its_mark():
    got = stressed_words([w("Бражничество,", 230, 420, stress=2, conf=0.85)])
    assert [(g.form, g.confidence) for g in got] == [(f"Бра{A}жничество", 0.85)]
    assert got[0].page == "p1"


def test_unmarked_words_and_low_confidence_marks_are_left_out():
    page = [w("что", 100, 100), w("Тоже,", 300, 100, stress=1, conf=0.3)]
    assert stressed_words(page, min_confidence=0.5) == []


def test_a_word_split_at_the_line_end_is_joined():
    page = [w("и", 100, 100), w("бражни-", 300, 100, stress=5, conf=0.9),
            w("чать,", 100, 160), w("и", 400, 160)]
    assert [g.form for g in stressed_words(page)] == [f"бражни{A}чать"]


def test_the_mark_may_sit_in_the_second_half():
    page = [w("ко-", 900, 100), w("рова", 100, 160, stress=1, conf=0.9)]
    assert [g.form for g in stressed_words(page)] == [f"коро{A}ва"]


def test_a_hyphen_inside_a_line_is_a_real_hyphen():
    page = [w("по-рыбьему,", 100, 100, stress=4, conf=0.9), w("и", 600, 100)]
    assert [g.form for g in stressed_words(page)] == [f"по-ры{A}бьему"]


def test_clean_maps_latin_look_alikes_and_rejects_junk():
    # Latin p, a in an OCR'd Cyrillic word; the mark is on index 2 (a).
    assert clean("Бpaжa,", 2) == f"Бра{A}жа"
    assert clean("бр&жни", 2) is None
    assert clean("Brot", 2) is None  # a German word from Pavlovsky


def test_clean_keeps_the_mark_on_its_letter_after_stripping_punctuation():
    assert clean("«Слово»,", 3) == f"Сло{A}во"
    assert clean("Ѣда.", 0) == f"Ѣ{A}да"
    assert clean("(слово)", 3) == f"сло{A}во"


def test_a_mark_on_a_consonant_is_not_a_stress():
    assert clean("Брат", 1) is None


def test_only_words_as_dense_as_the_measured_ones_are_kept():
    # Precision was measured on bold entry words; plain running text,
    # where no marks are printed, is left out.
    bold = dict(w("Коро́ва", 100, 100, stress=3, conf=0.9), word="Корова", density=0.55)
    plain = dict(w("будет", 400, 100, stress=1, conf=0.9), density=0.30)
    assert [g.form for g in stressed_words([bold, plain], min_density=0.5)] == [f"Коро{A}ва"]


def test_an_ending_printed_alone_is_not_a_word():
    # Dictionaries print endings ("-у́ша", "-а́да"); stripped of the hyphen
    # they pose as short real words (ада, аду) and false disputes follow.
    assert clean("-уша,", 1) is None  # the mark on у
    assert clean("уша,", 0) == f"у{A}ша"  # the same word without a hyphen
    page = [w("-ада", 100, 100, stress=1, conf=0.9)]
    assert stressed_words(page) == []
