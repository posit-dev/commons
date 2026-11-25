"""Tests for reading logged conversations with ``trajectory_read()``.

The cases live in ``tests/shared/trajectories/build.json``, and the R suite
runs the same cases, so a case belongs in the fixture rather than here. This
module adds only what the fixture cannot pin.
"""

import json
import time
from collections.abc import Iterator
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Any

import pytest
from chatlas.types import ContentToolRequest, ContentToolResult

import commons
from commons._trajectory import trajectory_read, window_bound
from commons._trajectory._otlp import EXPORTER_FILE_VAR, TRACES_DIR_VAR
from tests._connect_fake import connect_fixture_server, serve_connect
from tests._shared import SHARED_DIR
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
def _clean_trace_environment(
    monkeypatch: pytest.MonkeyPatch, tmp_path_factory: pytest.TempPathFactory
) -> None:
    for name in (
        EXPORTER_FILE_VAR,
        TRACES_DIR_VAR,
        "POSIT_PRODUCT",
        "CONNECT_CONTENT_GUID",
        "CONNECT_SERVER",
        "CONNECT_API_KEY",
    ):
        monkeypatch.delenv(name, raising=False)
    # A deployment record in the checkout, or a server registered with
    # rsconnect-python, would send a read with no source to Connect.
    home = tmp_path_factory.mktemp("home")
    for name in ("HOME", "XDG_CONFIG_HOME", "APPDATA"):
        monkeypatch.setenv(name, str(home))
    monkeypatch.chdir(tmp_path_factory.mktemp("project"))


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


def _conversation() -> list[dict[str, Any]]:
    (case,) = [
        c for c in BUILD["trace_id_fallback"]["cases"] if c["name"].startswith("a chat")
    ]
    return case["spans"]


def _write_conversation(directory: Path) -> None:
    trace = directory / "trace-1.jsonl"
    trace.write_text(fixture_line(_conversation()) + "\n", encoding="utf-8")


def test_a_path_source_reads_like_a_string(tmp_path: Path) -> None:
    _write_conversation(tmp_path)
    from_path = trajectory_read(tmp_path)
    from_string = trajectory_read(str(tmp_path))
    assert list(from_path) == list(from_string) == ["lonetrace"]
    assert described_turns(from_path["lonetrace"].turns) == described_turns(
        from_string["lonetrace"].turns
    )


def test_is_unlinked_result_tells_an_orphaned_result_apart(tmp_path: Path) -> None:
    """A caller needs an exact test for a result whose tool call was not
    recorded: its placeholder request has an empty name, and so can a
    recorded tool call."""
    spans = [
        {
            "trace": "t1",
            "span": "chat",
            "chat": True,
            "conversation": "conv-a",
            "end": "10",
            "input": [
                {"role": "user", "parts": [{"type": "text", "content": "Q1"}]},
                {
                    "role": "assistant",
                    "parts": [
                        {"type": "tool_call", "id": "c1", "name": "", "arguments": {}}
                    ],
                },
                {
                    "role": "tool",
                    "parts": [
                        {"type": "tool_call_response", "id": "c1", "response": "a"},
                        {"type": "tool_call_response", "id": "c9", "response": "b"},
                    ],
                },
            ],
            "output": [
                {"role": "assistant", "parts": [{"type": "text", "content": "A1"}]}
            ],
        }
    ]
    (tmp_path / "trace.jsonl").write_text(fixture_line(spans) + "\n", encoding="utf-8")
    (trajectory,) = commons.trajectory_read(tmp_path).values()
    results = [
        c
        for turn in trajectory.turns
        for c in turn.contents
        if isinstance(c, ContentToolResult)
    ]
    assert [r.value for r in results] == ["a", "b"]
    assert all(r.request is not None and r.request.name == "" for r in results)
    assert [commons.is_unlinked_result(r) for r in results] == [False, True]


@pytest.mark.parametrize(
    "source",
    [
        "01234567-89ab-cdef-0123-456789abcdef",
        "https://connect.example.com/content/01234567-89ab-cdef-0123-456789abcdef/",
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
    monkeypatch.setenv("CONNECT_SERVER", "https://connect.example.com")
    monkeypatch.setenv("CONNECT_API_KEY", "key")
    traces = [{**span, "conversation": "from-connect"} for span in _conversation()]
    serve_connect(
        monkeypatch,
        connect_fixture_server(
            {"version": "2026.09.0", "traces": [traces], "jobs": []}
        )[0],
    )

    assert list(trajectory_read(source)) == ["from-connect"]


def test_no_source_reads_the_python_deployment(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    guid = "ea3c1445-cb71-42df-a2f2-bdb18874ef41"
    server = "https://connect.example.com"
    record = {
        server: {
            "server_url": server,
            "filename": "app.py",
            "app_url": f"{server}/content/{guid}/",
            "app_id": "42",
            "app_guid": guid,
            "title": "My agent",
            "app_mode": "python-shiny",
            "app_store_version": 1,
        }
    }
    store = tmp_path / "rsconnect-python"
    store.mkdir()
    (store / "app.json").write_text(json.dumps(record), encoding="utf-8")
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("CONNECT_API_KEY", "key")
    traces = [{**span, "conversation": "deployed"} for span in _conversation()]
    route, seen = connect_fixture_server(
        {"version": "2026.09.0", "traces": [traces], "jobs": []}
    )
    serve_connect(monkeypatch, route)

    assert list(trajectory_read()) == ["deployed"]
    assert str(seen[0].url).startswith(f"{server}/__api__/v1/content/{guid}/")


def test_no_source_reads_the_traces_directory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv(TRACES_DIR_VAR, str(tmp_path))
    _write_conversation(tmp_path)
    assert list(trajectory_read()) == ["lonetrace"]


def test_an_empty_path_reads_nothing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # R's dir.exists("") is FALSE; Path("") would be the working directory.
    _write_conversation(tmp_path)
    monkeypatch.chdir(tmp_path)
    assert trajectory_read("") == {}
    assert trajectory_read(_EmptyPath()) == {}


class _EmptyPath:
    def __fspath__(self) -> str:
        return ""


@pytest.mark.parametrize("member", ["contentless", "conflicting_records"])
def test_a_warning_points_at_the_caller(member: str, tmp_path: Path) -> None:
    case = next(c for c in BUILD[member]["cases"] if c.get("notice") == "warning")
    trace = tmp_path / "trace-1.jsonl"
    trace.write_text(fixture_line(case["spans"]) + "\n", encoding="utf-8")
    with pytest.warns(UserWarning) as caught:
        trajectory_read(tmp_path)
    assert [w.filename for w in caught] == [__file__]


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


TRACES = SHARED_DIR / "traces"
WRITERS = ("python", "r")


@pytest.mark.parametrize("writer", WRITERS)
def test_each_committed_trace_reads_as_expected(writer: str) -> None:
    expected = json.loads(
        (TRACES / writer / "expected.json").read_text(encoding="utf-8")
    )
    trajectories = commons.trajectory_read(str(TRACES / writer))

    assert len(trajectories) == len(expected["conversations"])
    for trajectory, want in zip(
        trajectories.values(), expected["conversations"], strict=True
    ):
        turns = trajectory.turns
        assert [turn.role for turn in turns] == want["roles"]
        contents = [c for turn in turns for c in turn.contents]
        requests = [c for c in contents if isinstance(c, ContentToolRequest)]
        results = [c for c in contents if isinstance(c, ContentToolResult)]
        if want["tool"] is None:
            assert requests == []
        else:
            (request,) = [r for r in requests if r.name == want["tool"]["name"]]
            linked = [r for r in results if r.request is request]
            assert len(linked) == (1 if want["tool"]["linked"] else 0)
        assert [
            None if r.tag is None else str(r.tag) for r in trajectory.exchanges
        ] == [e["provenance_tag"] for e in want["exchanges"]]
        assert [[d.status for d in r.decisions] for r in trajectory.exchanges] == [
            e["decision_statuses"] for e in want["exchanges"]
        ]
        assert trajectory.user is None
