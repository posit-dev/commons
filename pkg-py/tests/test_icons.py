"""Icon URLs, resolved against whichever asset bundle is being served."""

from typing import get_args

import pytest

from commons._citations import CitationKind, citation_icon_url
from commons._icons import get_asset_base_url, icon_url, set_asset_base_url
from commons._provenance import PROVENANCE_DISPLAY

KIND_ICONS = {
    "prose": "citation-prose.svg",
    "definition": "citation-definition.svg",
    "schema": "citation-schema.svg",
}


def test_nothing_resolves_until_a_bundle_is_served() -> None:
    assert get_asset_base_url() is None
    assert icon_url("citation-mark.svg") is None


def test_a_served_bundle_holds_its_icons_under_figs(served_bundle: str) -> None:
    assert icon_url("citation-mark.svg") == f"{served_bundle}/figs/citation-mark.svg"


def test_a_file_the_bundle_does_not_ship_has_no_icon(served_bundle: str) -> None:
    # A URL under the served path that no file backs renders as a broken
    # image, which is worse than no icon.
    assert icon_url("missing.svg") is None


def test_a_marker_that_names_no_icon_resolves_to_none(served_bundle: str) -> None:
    assert icon_url(None) is None


def test_the_kinds_with_an_icon_are_every_kind_there_is() -> None:
    assert set(KIND_ICONS) == set(get_args(CitationKind))


@pytest.mark.parametrize(("kind", "file"), KIND_ICONS.items())
def test_each_citation_kind_names_its_own_icon(
    kind: str, file: str, served_bundle: str
) -> None:
    assert citation_icon_url(kind) == f"{served_bundle}/figs/{file}"


def test_an_unknown_citation_kind_has_no_icon(served_bundle: str) -> None:
    # The kind arrives off a verified corpus entry, but a kind added without
    # an icon must render its aside rather than a broken image.
    assert citation_icon_url("unknown") is None


def test_every_provenance_icon_is_a_file_the_bundle_ships(served_bundle: str) -> None:
    named = [d.icon for d in PROVENANCE_DISPLAY.values() if d.icon is not None]

    assert named
    assert all(icon_url(file) is not None for file in named)


def test_a_bundle_can_be_taken_away_again(served_bundle: str) -> None:
    set_asset_base_url(None)

    assert icon_url("citation-mark.svg") is None
