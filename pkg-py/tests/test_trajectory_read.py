"""Tests for reading logged conversations with ``trajectory_read()``.

The cases live in ``tests/shared/trajectories/build.json``, and the R suite
runs the same cases, so a case belongs in the fixture rather than here. This
module adds only what the fixture cannot pin.
"""

import time
from collections.abc import Iterator
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

import pytest

from commons._trajectory import trajectory_read, window_bound
from commons._trajectory._otlp import EXPORTER_FILE_VAR, TRACES_DIR_VAR
from tests._trajectories import (
    BOUND_MEMBERS,
    BUILD,
    BUILD_MEMBERS,
    READ_MEMBERS,
    assert_trajectories,
    cases,
    described_turns,
    fixture_line,
    run_case,
)


@pytest.fixture(autouse=True)
def _clean_trace_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv(EXPORTER_FILE_VAR, raising=False)
    monkeypatch.delenv(TRACES_DIR_VAR, raising=False)
    monkeypatch.delenv("POSIT_PRODUCT", raising=False)
    monkeypatch.delenv("CONNECT_CONTENT_GUID", raising=False)


@pytest.fixture
def denver(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setenv("TZ", "America/Denver")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


def test_every_member_is_run() -> None:
    assert set(BUILD) - {"description"} == {
        *BUILD_MEMBERS,
        *READ_MEMBERS,
        *BOUND_MEMBERS,
    }


@pytest.mark.parametrize(("member", "case"), cases(READ_MEMBERS))
def test_a_directory_reads_as_the_shared_fixture_pins(
    member: dict[str, Any], case: dict[str, Any], tmp_path: Path
) -> None:
    if case.get("error"):
        with pytest.raises((TypeError, ValueError)):
            run_case(member, case, tmp_path)
        return
    trajectories, notices = run_case(member, case, tmp_path)
    assert notices == ([] if case.get("notice") is None else [case["notice"]])
    assert_trajectories(trajectories, case["trajectories"])


def _write_conversation(directory: Path) -> None:
    (case,) = [
        c for c in BUILD["trace_id_fallback"]["cases"] if c["name"].startswith("a chat")
    ]
    trace = directory / "trace-1.jsonl"
    trace.write_text(fixture_line(case["spans"]) + "\n", encoding="utf-8")


def test_a_path_source_reads_like_a_string(tmp_path: Path) -> None:
    _write_conversation(tmp_path)
    from_path = trajectory_read(tmp_path)
    from_string = trajectory_read(str(tmp_path))
    assert list(from_path) == list(from_string) == ["lonetrace"]
    assert described_turns(from_path["lonetrace"].turns) == described_turns(
        from_string["lonetrace"].turns
    )


@pytest.mark.parametrize(
    "source",
    [
        "01234567-89ab-cdef-0123-456789abcdef",
        "https://connect.example.com/content/01234567-89ab-cdef-0123-456789abcdef/",
        "http://connect.example.com/content/my-app/",
    ],
)
def test_a_connect_source_is_not_read_locally(
    source: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # A local read would find this directory, relative to the working directory.
    local = tmp_path / source
    local.mkdir(parents=True)
    _write_conversation(local)
    monkeypatch.chdir(tmp_path)
    with pytest.raises(NotImplementedError, match="not supported yet"):
        trajectory_read(source)


def test_no_source_on_connect_is_not_supported_yet(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("CONNECT_SERVER", "https://connect.example.com")
    monkeypatch.setenv("CONNECT_CONTENT_GUID", "01234567-89ab-cdef-0123-456789abcdef")
    with pytest.raises(NotImplementedError, match="not supported yet"):
        trajectory_read()


def test_no_source_reads_the_traces_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(TRACES_DIR_VAR, str(tmp_path))
    _write_conversation(tmp_path)
    assert list(trajectory_read()) == ["lonetrace"]


def test_a_source_of_another_type_is_rejected() -> None:
    with pytest.raises(TypeError, match="source must be"):
        trajectory_read(3)  # type: ignore[arg-type]


_UTC = "%Y-%m-%d %H:%M:%S"


@pytest.mark.parametrize(("member", "case"), cases(BOUND_MEMBERS))
def test_window_bounds_parse_as_the_shared_fixture_pins(
    member: dict[str, Any], case: dict[str, Any], denver: None
) -> None:
    value = date.fromisoformat(case["date"]) if "date" in case else case["string"]
    if case["utc"] is None:
        with pytest.raises(ValueError, match="must be"):
            window_bound(value, "since")
    else:
        expected = datetime.strptime(case["utc"], _UTC).replace(tzinfo=UTC)
        assert window_bound(value, "since") == expected


def test_an_aware_datetime_is_kept() -> None:
    at = datetime(2026, 7, 22, 14, 30, tzinfo=UTC)
    assert window_bound(at, "since") == at


def test_a_naive_datetime_is_local_time(denver: None) -> None:
    naive = datetime(2026, 7, 22, 14, 30)  # noqa: DTZ001
    assert window_bound(naive, "until") == datetime(2026, 7, 22, 20, 30, tzinfo=UTC)


def test_a_datetime_keeps_its_time(denver: None) -> None:
    # datetime subclasses date, so a check for date first would drop the time.
    at = datetime(2026, 7, 22, 14, 30, tzinfo=UTC)
    bound = window_bound(at, "since")
    assert bound is not None
    assert bound.astimezone(UTC).time() == at.time()


def test_a_bound_of_another_type_is_rejected(tmp_path: Path) -> None:
    with pytest.raises(TypeError, match="until must be"):
        window_bound(1.5, "until")
    with pytest.raises(TypeError, match="since must be"):
        trajectory_read(tmp_path, since=["2026-07-22"])  # type: ignore[arg-type]
