"""Where each stress entry came from, and the one rule on it: an AI's
answer may go into the lookup table the app reads, never into anything
a model learns from (owner, 14 Nov 2026: "Never generate training
pairs")."""

from dataclasses import dataclass

#: The scans agree on it; one book prints it (17 Nov: a printed mark, not
#: an AI's answer, so trainable); a rule that is always true; an AI read
#: the scan.
KINDS = ("scan-agree", "scan-single", "rule", "ai-checked")
TRAINABLE = ("scan-agree", "scan-single", "rule")


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
