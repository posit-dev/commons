"""A/B/C provenance: how much an answer can be trusted.

The truth table and the display copy are a cross-language contract pinned by
``tests/shared/provenance.json``; change that fixture, not just this file.
``pkg-r/R/provenance.R`` implements the same contract for R.
"""

from __future__ import annotations

import enum
from collections.abc import Sequence
from dataclasses import dataclass

__all__ = ["PROVENANCE_DISPLAY", "ProvenanceDisplay", "Tag", "derive_provenance_tag"]


class Tag(enum.StrEnum):
    """How an answer was produced.

    A and B are set by tools on their results. C is only ever derived: it is
    what a B becomes when its citation does not verify.

    StrEnum rather than a plain `str, Enum` mixin, which formats as "Tag.A".
    The tag is written to the commons.provenance.tag span attribute, where R
    writes the bare letter and a mismatch would corrupt traces silently.
    """

    A = "A"
    B = "B"
    C = "C"


@dataclass(frozen=True)
class ProvenanceDisplay:
    """The words and styling one tag's provenance marker renders with."""

    label: str
    icon: str | None
    body: str
    dot_class: str | None


PROVENANCE_DISPLAY: dict[Tag, ProvenanceDisplay] = {
    Tag.A: ProvenanceDisplay(
        label="Verified answer",
        icon="trusted-icon.svg",
        body=(
            "This answer comes from a governed calculation defined by your data team."
        ),
        dot_class="verified",
    ),
    Tag.B: ProvenanceDisplay(
        label="Cited",
        icon=None,
        body="This answer includes supporting text verified against a trusted source.",
        dot_class=None,
    ),
    Tag.C: ProvenanceDisplay(
        label="Untrusted",
        icon="warning-icon.svg",
        body=(
            "This answer was not produced by a governed calculation and has "
            "no verified supporting citation. AI can be wrong."
        ),
        dot_class="untrusted",
    ),
}


def derive_provenance_tag(tags: Sequence[Tag], verified: bool) -> Tag | None:
    """Classify one exchange from the tags its tools set.

    A fallback claim remains fallback even when its answer also uses a governed
    calculation, so its citation verdict takes precedence ("B beats A").
    Returns ``None`` when no data tool ran, which shows no provenance marker.
    """
    if Tag.B in tags:
        return Tag.B if verified else Tag.C
    if Tag.A in tags:
        return Tag.A
    return None
