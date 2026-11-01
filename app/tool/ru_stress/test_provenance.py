"""No training pairs from an AI (owner, 14 Nov 2026): the guesser's
training export takes only rows the scans agree on, or rules."""

import pytest

from provenance import Entry, NotTrainable, lookup_rows, training_rows


def rows():
    return [
        Entry("сло́во", "scan-agree"),
        Entry("до́м", "rule"),
        Entry("за́мок", "ai-checked"),
    ]


def test_the_lookup_table_takes_every_row():
    assert [e.word for e in lookup_rows(rows())] == [
        "сло́во", "до́м", "за́мок"]


def test_training_refuses_an_ai_checked_row():
    with pytest.raises(NotTrainable, match="за́мок"):
        training_rows(rows())


def test_training_takes_scan_and_rule_rows():
    assert [e.word for e in training_rows(rows()[:2])] == [
        "сло́во", "до́м"]


def test_an_unknown_provenance_is_refused_everywhere():
    with pytest.raises(ValueError):
        Entry("кот", "guess")
