"""Where each stress entry came from, and the one rule on it: an AI's
answer may go into the lookup table the app reads, never into anything
a model learns from (owner, 14 Nov 2026: "Never generate training
pairs")."""

from dataclasses import dataclass

#: The scans agree on it; a rule that is always true; an AI read the scan.
KINDS = ("scan-agree", "rule", "ai-checked")
TRAINABLE = ("scan-agree", "rule")


class NotTrainable(Exception):
    pass


@dataclass(frozen=True)
class Entry:
    word: str
    provenance: str

    def __post_init__(self):
        if self.provenance not in KINDS:
            raise ValueError(f"unknown provenance {self.provenance!r}")


def lookup_rows(entries):
    """Every entry: the app's lookup table takes them all."""
    return list(entries)


def training_rows(entries):
    """The entries a model may learn from. Refuses the whole export if
    any row is not trainable, so a mixed list is never trimmed quietly."""
    entries = list(entries)
    bad = [e.word for e in entries if e.provenance not in TRAINABLE]
    if bad:
        raise NotTrainable(f"not trainable: {', '.join(bad[:5])}")
    return entries
