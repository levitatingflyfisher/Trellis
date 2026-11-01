# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest"]
# ///
"""A stress the scans agree on, carried to the other forms of the word when
it sits in the part every form shares (plan step 6, stress classes).
Run: uv run --with pytest --with numpy pytest app/tool/ru_stress"""

from classes import carry, Rule

# Hunspell-style suffix rules: flag -> [(strip, add)].
RULES = {
    "A": [Rule("а", "и"), Rule("а", "е"), Rule("а", "у"), Rule("а", "ой")],
}


def test_a_stem_stress_goes_to_every_form():
    entries = [("дорога", "A")]
    got = carry(entries, RULES, agree={"дорога": 1})
    assert got == {"дороги": 1, "дороге": 1, "дорогу": 1, "дорогой": 1}


def test_a_stress_on_the_ending_is_not_carried():
    # рука́ but ру́ку: the stress moves, so nothing is carried.
    got = carry([("рука", "A")], RULES, agree={"рука": 1})
    assert got == {}


def test_forms_that_disagree_carry_nothing():
    got = carry([("дорога", "A")], RULES, agree={"дорога": 1, "дороги": 0})
    assert got == {}


def test_a_form_two_words_share_with_two_stresses_is_left_out():
    # Two entries make the same form with different stresses.
    rules = {"A": [Rule("и", "у")], "B": [Rule("о", "у")]}
    entries = [("барани", "A"), ("барано", "B")]
    got = carry(entries, rules, agree={"барани": 0, "барано": 1})
    assert "барану" not in got
    # Each alone would carry it.
    assert carry(entries[:1], rules, agree={"барани": 0}) == {"барану": 0}


def test_an_agreed_word_is_never_changed():
    got = carry([("дорога", "A")], RULES, agree={"дорога": 1, "дорогу": 1})
    assert "дорогу" not in got
    assert got["дороги"] == 1


def test_with_min_known_one_form_is_not_enough():
    # One stem-stressed form proves little: прика́жешь, then приказа́л.
    assert carry([("дорога", "A")], RULES, agree={"дорога": 1},
                 min_known=2) == {}
    got = carry([("дорога", "A")], RULES, agree={"дорога": 1, "дороги": 1},
                min_known=2)
    assert got == {"дороге": 1, "дорогу": 1, "дорогой": 1}
