"""Tests for reading trajectories from Posit Connect.

The cases live in ``tests/shared/trajectories/connect.json``, and the R suite
runs the same cases, so a case belongs in the fixture rather than here. This
module adds only what the fixture cannot pin.
"""

from collections.abc import Sequence
from datetime import UTC, datetime, timedelta, timezone
from typing import Any

import pytest

from commons._connect import FROM_PAD, TO_PAD, window_param
from commons._trajectory._source import (
    content_url_guid,
    content_vanity_url,
    is_content_guid,
)
from tests._shared import load_shared_fixture

CONNECT = load_shared_fixture("trajectories/connect")
GUID = "ea3c1445-cb71-42df-a2f2-bdb18874ef41"
PARSE_MEMBERS = ("content_guid", "content_url", "vanity_url", "window_param")


def cases(members: Sequence[str]) -> list[Any]:
    return [
        pytest.param(CONNECT[m], case, id=f"{m}: {case['name']}")
        for m in members
        for case in CONNECT[m]["cases"]
    ]


def _named(member: str) -> Any:
    return pytest.mark.parametrize(
        "case", CONNECT[member]["cases"], ids=lambda case: case["name"]
    )


def test_every_member_is_run() -> None:
    assert set(CONNECT) - {"description"} == {*PARSE_MEMBERS}


@_named("content_guid")
def test_content_guids_match_the_shared_fixture(case: dict[str, Any]) -> None:
    assert is_content_guid(case["text"]) is case["expected"]


@_named("content_url")
def test_content_urls_match_the_shared_fixture(case: dict[str, Any]) -> None:
    expected = case["expected"]
    assert content_url_guid(case["url"]) == (
        None if expected is None else (expected["server"], expected["guid"])
    )


@_named("vanity_url")
def test_vanity_urls_match_the_shared_fixture(case: dict[str, Any]) -> None:
    expected = case["expected"]
    assert content_vanity_url(case["url"]) == (
        None if expected is None else (expected["server"], expected["query"])
    )


@_named("window_param")
def test_window_params_match_the_shared_fixture(case: dict[str, Any]) -> None:
    at = datetime.fromtimestamp(case["at"], UTC)
    assert window_param(at, timedelta(seconds=case["pad"])) == case["expected"]


def test_no_bound_sends_no_param() -> None:
    assert window_param(None, FROM_PAD) is None


def test_an_aware_bound_in_another_zone_is_sent_in_utc() -> None:
    at = datetime(2026, 7, 22, 8, 30, tzinfo=timezone(timedelta(hours=-6)))
    assert window_param(at, TO_PAD) == "2026-07-22T14:30:01Z"
