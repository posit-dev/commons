"""A/B/C provenance: how much an answer can be trusted.

The truth table, the display copy, and which outcomes render a marker are a
cross-language contract pinned by ``tests/shared/provenance.json``; change
that fixture, not just this file. ``pkg-r/R/provenance.R`` implements the same
contract for R.
"""

from __future__ import annotations

import enum
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Final

from chatlas import ContentToolResult, Turn

from ._icons import icon_url

__all__ = [
    "PROVENANCE_DISPLAY",
    "TAG_EXTRA_KEY",
    "ProvenanceDisplay",
    "Tag",
    "collect_appended_tags",
    "derive_provenance_tag",
    "escape_attr",
    "provenance_aside",
]

# Where a tool records how much its result can be trusted. R writes the same
# key, so a trajectory written by either package classifies in both.
TAG_EXTRA_KEY: Final = "commons_tag"


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
    """The words and styling one tag's pill renders with."""

    label: str
    icon: str | None
    body: str
    pill_class: str


PROVENANCE_DISPLAY: dict[Tag, ProvenanceDisplay] = {
    Tag.A: ProvenanceDisplay(
        label="Verified answer",
        icon="trusted-icon.svg",
        body="This answer comes from a trusted calculation.",
        pill_class="trusted",
    ),
    Tag.B: ProvenanceDisplay(
        label="Cited",
        icon=None,
        body=(
            "This answer cites context from a trusted source that supports its "
            "approach."
        ),
        pill_class="cited",
    ),
    Tag.C: ProvenanceDisplay(
        label="Untrusted",
        icon="warning-icon.svg",
        body=(
            "This answer was not produced by a trusted calculation and does not "
            "cite trusted context."
        ),
        pill_class="caution",
    ),
}


def derive_provenance_tag(tags: Sequence[Tag], verified: bool) -> Tag | None:
    """Classify one exchange from the tags its tools set.

    A fallback claim remains fallback even when its answer also uses a governed
    calculation, so its citation verdict takes precedence ("B beats A").
    Returns ``None`` when no data tool ran, which shows no pill at all.
    """
    if Tag.B in tags:
        return Tag.B if verified else Tag.C
    if Tag.A in tags:
        return Tag.A
    return None


def collect_appended_tags(turns: Sequence[Turn], from_index: int) -> list[Tag]:
    """Gather the tags the tools of one exchange set on their results.

    ``from_index`` is the turn count read before the exchange started, so a
    tag an earlier answer earned cannot classify this one.
    """
    tags: list[Tag] = []
    for turn in turns[from_index:]:
        for content in turn.contents:
            if not isinstance(content, ContentToolResult):
                continue
            value = (content.extra or {}).get(TAG_EXTRA_KEY)
            try:
                tags.append(Tag(value))
            # Nothing validates `extra`, and a restored conversation arrives
            # as JSON: an unreadable tag must not cost the exchange the tags
            # that are readable.
            except ValueError:
                continue
    return tags


def escape_attr(text: str) -> str:
    """Escape ``&`` and ``"`` for a double-quoted HTML attribute value.

    Nothing else is escaped, so the result belongs in a double-quoted
    attribute only: never a text node, never a single-quoted attribute.
    """
    # Ampersands first, so the entities this generates are not escaped again.
    return text.replace("&", "&amp;").replace('"', "&quot;")


# Upgrades when the UI mounts the aside, and renders as nothing until then.
_INFO_CONTROL: Final = (
    '<commons-provenance-info class="commons-provenance-info">'
    "</commons-provenance-info>"
)


def provenance_aside(tag: Tag | None, *, include_cited: bool = False) -> str:
    """Render the marker that follows a classified answer.

    Which outcomes render is a cross-language contract pinned by
    ``tests/shared/provenance.json``. A live answer omits the "Cited" marker,
    because the verified citation's own aside already says as much; a review
    context passes ``include_cited`` to see every outcome.

    The outcome's icon is omitted when no asset bundle serves it.
    """
    if tag is None or (tag is Tag.B and not include_cited):
        return ""
    display = PROVENANCE_DISPLAY[tag]
    icon = icon_url(display.icon)
    icon_attr = "" if icon is None else f' icon="{escape_attr(icon)}"'
    return (
        f'<shiny-aside label="{escape_attr(display.label)}"{icon_attr}>'
        f"{display.body} {_INFO_CONTROL}</shiny-aside>"
    )
