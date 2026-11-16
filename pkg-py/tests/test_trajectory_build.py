"""Tests for rebuilding conversations from recorded spans.

The cases live in ``tests/shared/trajectories/build.json``, and the R suite
runs the same cases, so a case belongs in the fixture rather than here. This
module adds only what the fixture cannot pin.
"""

from datetime import UTC, datetime
from typing import Any

import pytest
from chatlas import Turn

from commons._trajectory._build import ExchangeProvenance, Trajectory
from tests._trajectories import (
    BUILD,
    BUILD_MEMBERS,
    assert_trajectories,
    cases,
    run_case,
)


def test_the_build_members_have_cases() -> None:
    for member in BUILD_MEMBERS:
        assert BUILD[member]["cases"], member


@pytest.mark.parametrize(("member", "case"), cases(BUILD_MEMBERS))
def test_spans_build_as_the_shared_fixture_pins(
    member: dict[str, Any], case: dict[str, Any]
) -> None:
    trajectories, notices = run_case(member, case)
    assert notices == ([] if case.get("notice") is None else [case["notice"]])
    assert_trajectories(trajectories, case["trajectories"])


def test_a_trajectory_has_the_public_types() -> None:
    (case,) = [c for c in BUILD["last_active"]["cases"] if c["name"].startswith("each")]
    trajectories, _ = run_case(BUILD["last_active"], case)
    trajectory = trajectories["t100"]
    assert isinstance(trajectory, Trajectory)
    assert trajectory.last_active == datetime(1970, 1, 1, 0, 1, 41, tzinfo=UTC)
    assert trajectory.last_active.tzinfo is UTC
    assert all(isinstance(turn, Turn) for turn in trajectory.turns)
    assert all(isinstance(r, ExchangeProvenance) for r in trajectory.provenance)
