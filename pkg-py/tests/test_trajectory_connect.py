"""Tests for reading trajectories from Posit Connect.

The cases live in ``tests/shared/trajectories/connect.json``, and the R suite
runs the same cases, so a case belongs in the fixture rather than here. This
module adds only what the fixture cannot pin.
"""

import json
import logging
import os
import sys
import warnings
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import pytest

from commons._connect import FROM_PAD, TO_PAD, normalize_server, window_param
from commons._tracing import CONTENT_TRACING_HINT, SERVER_TRACING_HINT
from commons._trajectory import trajectory_read
from commons._trajectory._build import has_severed_ancestry
from commons._trajectory._deployment import (
    find_deployment,
    registered_connect_servers,
)
from commons._trajectory._otlp import parse_otlp_lines
from commons._trajectory._source import (
    ConnectSource,
    LocalSource,
    content_url_guid,
    content_vanity_url,
    enough_trace_lines,
    is_content_guid,
    resolve_trajectory_source,
)
from tests._connect_fake import connect_fixture_server, serve_connect
from tests._shared import load_shared_fixture
from tests._trajectories import _instant, assert_trajectories, fixture_line, read_case

CONNECT = load_shared_fixture("trajectories/connect")
GUID = "ea3c1445-cb71-42df-a2f2-bdb18874ef41"
PARSE_MEMBERS = ("content_guid", "content_url", "vanity_url", "window_param")
RECORD_MEMBERS = ("record_search", "record_fields")
SOURCE_MEMBERS = (
    "guid_source",
    "guid_server",
    "content_url_source",
    "dashboard_url_source",
    "vanity_source",
    "unrecognized_url",
    "null_on_connect",
    "null_deployment",
    "null_local",
)
CHECK_MEMBERS = ("enough", "enough_ancestry", "severed")
READ_MEMBERS = ("refetch", "fetch_once", "early_stop", "empty_read")
_CLEARED = (
    "POSIT_PRODUCT",
    "CONNECT_CONTENT_GUID",
    "CONNECT_SERVER",
    "OTEL_EXPORTER_OTLP_TRACES_FILE",
    "COMMONS_TRACES_DIR",
)


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


@pytest.fixture(autouse=True)
def _isolated_home(
    monkeypatch: pytest.MonkeyPatch, tmp_path_factory: pytest.TempPathFactory
) -> None:
    # A developer's rsconnect-python store would otherwise name their servers.
    home = tmp_path_factory.mktemp("home")
    for name in ("HOME", "XDG_CONFIG_HOME", "APPDATA"):
        monkeypatch.setenv(name, str(home))


def write_fixture_files(directory: Path, case: dict[str, Any]) -> None:
    for name, lines in case.get("files", {}).items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    for name, mtime in case.get("mtime", {}).items():
        os.utime(directory / name, (mtime, mtime))


def connect_env(monkeypatch: pytest.MonkeyPatch, env: dict[str, str | None]) -> None:
    for name in _CLEARED:
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("CONNECT_API_KEY", "key")
    for name, value in env.items():
        if value is None:
            monkeypatch.delenv(name, raising=False)
        else:
            monkeypatch.setenv(name, value)


def test_every_member_is_run() -> None:
    assert set(CONNECT) - {"description"} == {
        *PARSE_MEMBERS,
        *RECORD_MEMBERS,
        *SOURCE_MEMBERS,
        *CHECK_MEMBERS,
        *READ_MEMBERS,
    }


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


def test_a_bound_in_a_repeated_hour_is_padded_in_utc() -> None:
    # 01:30 on the second pass through Denver's repeated hour is 08:30 UTC.
    # Padding in local time would shift it by the hour that repeats.
    at = datetime(2026, 11, 1, 1, 30, fold=1, tzinfo=ZoneInfo("America/Denver"))
    assert window_param(at, TO_PAD) == "2026-11-01T08:30:01Z"


def test_a_bound_padded_out_of_range_is_not_sent() -> None:
    assert window_param(datetime.min.replace(tzinfo=UTC), FROM_PAD) is None
    assert window_param(datetime.max.replace(tzinfo=UTC), TO_PAD) is None


@pytest.mark.parametrize(("member", "case"), cases(RECORD_MEMBERS))
def test_deployment_records_match_the_shared_fixture(
    member: dict[str, Any],
    case: dict[str, Any],
    tmp_path: Path,
    caplog: pytest.LogCaptureFixture,
) -> None:
    write_fixture_files(tmp_path, case)
    with caplog.at_level(logging.INFO, logger="commons._trajectory"):
        found = find_deployment(tmp_path)
    expected = case["expected"]
    assert (
        None
        if found is None
        else {"guid": found.guid, "server": normalize_server(found.server)}
    ) == expected
    assert ["message"] * len(caplog.records) == case.get("notice", [])


def _python_record(
    server: str = "https://connect.example.com",
    *,
    guid: str = GUID,
    title: str = "My agent",
    app_url: str | None = None,
) -> dict[str, Any]:
    # An entry as rsconnect-python 1.33 writes it.
    return {
        "server_url": server,
        "filename": "app.py",
        "app_url": f"{server}/content/{guid}/" if app_url is None else app_url,
        "app_id": "42",
        "app_guid": guid,
        "title": title,
        "app_mode": "python-shiny",
        "app_store_version": 1,
    }


def _write_python_record(path: Path, *entries: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    record = {entry["server_url"]: entry for entry in entries}
    path.write_text(json.dumps(record), encoding="utf-8")


def test_a_python_deployment_record_is_read(tmp_path: Path) -> None:
    _write_python_record(
        tmp_path / "app" / "rsconnect-python" / "app.json", _python_record()
    )

    found = find_deployment(tmp_path)

    assert found is not None
    assert (found.guid, found.server, found.name) == (
        GUID,
        "https://connect.example.com",
        "My agent",
    )


def test_a_python_record_keyed_by_a_cloud_account_is_skipped(tmp_path: Path) -> None:
    record = _python_record("https://api.connect.posit.cloud/v1#acct")
    _write_python_record(tmp_path / "rsconnect-python" / "app.json", record)

    assert find_deployment(tmp_path) is None


def test_a_python_record_without_a_guid_or_content_url_is_skipped(
    tmp_path: Path,
) -> None:
    # As rsconnect-python records a shinyapps.io deployment.
    record = _python_record(app_url="https://me.shinyapps.io/app/")
    record["app_guid"] = None
    _write_python_record(tmp_path / "rsconnect-python" / "app.json", record)

    assert find_deployment(tmp_path) is None


def test_a_python_record_with_a_vanity_url_is_read_by_its_guid(
    tmp_path: Path,
) -> None:
    record = _python_record(app_url="https://connect.example.com/my-agent/")
    _write_python_record(tmp_path / "rsconnect-python" / "app.json", record)

    found = find_deployment(tmp_path)

    assert found is not None
    assert found.guid == GUID


def test_a_python_record_without_a_guid_falls_back_to_its_url(
    tmp_path: Path,
) -> None:
    record = _python_record()
    record["app_guid"] = "not-a-guid"
    _write_python_record(tmp_path / "rsconnect-python" / "app.json", record)

    found = find_deployment(tmp_path)

    assert found is not None
    assert found.guid == GUID


def test_a_python_record_that_is_not_an_object_is_skipped(tmp_path: Path) -> None:
    store = tmp_path / "rsconnect-python"
    store.mkdir()
    for name, text in [
        ("a.json", "[]"),
        ("b.json", '"text"'),
        ("c.json", '{"x": 3}'),
        ("d.json", "not json"),
    ]:
        (store / name).write_text(text, encoding="utf-8")

    assert find_deployment(tmp_path) is None

    _write_python_record(store / "app.json", _python_record())
    found = find_deployment(tmp_path)

    assert found is not None
    assert found.guid == GUID


def test_a_python_record_beside_its_entry_point_only(tmp_path: Path) -> None:
    path = tmp_path / "rsconnect-python" / "nested" / "app.json"
    _write_python_record(path, _python_record())

    assert find_deployment(tmp_path) is None


def test_records_of_both_tools_are_ordered_by_modification_time(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    other = "01234567-89ab-cdef-0123-456789abcdef"
    dcf = "rsconnect/connect.example.com/me/r-agent.dcf"
    write_fixture_files(
        tmp_path,
        {
            "files": {
                dcf: [
                    "name: r-agent",
                    "hostUrl: https://connect.example.com/__api__",
                    f"url: https://connect.example.com/content/{other}/",
                ]
            }
        },
    )
    python = tmp_path / "rsconnect-python" / "app.json"
    _write_python_record(python, _python_record())

    os.utime(tmp_path / dcf, (1784000000, 1784000000))
    os.utime(python, (1784700000, 1784700000))
    with caplog.at_level(logging.INFO, logger="commons._trajectory"):
        found = find_deployment(tmp_path)
    assert found is not None
    assert found.guid == GUID
    assert len(caplog.records) == 1

    os.utime(tmp_path / dcf, (1784700000, 1784700000))
    os.utime(python, (1784000000, 1784000000))
    found = find_deployment(tmp_path)
    assert found is not None
    assert found.guid == other


def test_a_python_record_for_two_servers_reports_one(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    other = "01234567-89ab-cdef-0123-456789abcdef"
    _write_python_record(
        tmp_path / "rsconnect-python" / "app.json",
        _python_record("https://one.example.com"),
        _python_record("https://two.example.com", guid=other),
    )

    with caplog.at_level(logging.INFO, logger="commons._trajectory"):
        found = find_deployment(tmp_path)

    assert found is not None
    assert (found.guid, found.server) == (GUID, "https://one.example.com")
    assert len(caplog.records) == 1


def _store_dir() -> Path:
    # Where rsconnect-python 1.33 keeps servers.json, given _isolated_home's
    # HOME, XDG_CONFIG_HOME, and APPDATA, which are one directory.
    home = Path(os.environ["HOME"])
    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / "rsconnect-python"
    return home / ".rsconnect-python"


def _write_servers(entries: list[dict[str, str]]) -> None:
    directory = _store_dir()
    directory.mkdir(parents=True, exist_ok=True)
    servers = {entry["name"]: entry for entry in entries}
    (directory / "servers.json").write_text(json.dumps(servers), encoding="utf-8")


def _server(name: str, url: str) -> dict[str, str]:
    return {"name": name, "url": url, "api_key": "key"}


def test_the_one_registered_server_is_used() -> None:
    _write_servers(
        [
            _server("connect", "https://connect.example.com/__api__/"),
            _server("shinyapps", "https://api.shinyapps.io"),
            _server("cloud", "https://api.connect.posit.cloud/v1"),
        ]
    )

    assert registered_connect_servers() == ["https://connect.example.com"]


def test_several_registered_servers_are_all_listed() -> None:
    _write_servers(
        [
            _server("a", "https://one.example.com"),
            _server("b", "https://two.example.com/"),
            _server("c", "https://one.example.com/__api__"),
        ]
    )

    assert registered_connect_servers() == [
        "https://one.example.com",
        "https://two.example.com",
    ]


def test_no_registered_servers_without_a_store() -> None:
    assert registered_connect_servers() == []


@pytest.mark.parametrize("text", ["not json", "[]", '{"a": "https://x.example.com"}'])
def test_a_store_that_is_not_read_registers_no_servers(text: str) -> None:
    _store_dir().mkdir(parents=True)
    (_store_dir() / "servers.json").write_text(text, encoding="utf-8")

    assert registered_connect_servers() == []


@pytest.mark.parametrize(("member", "case"), cases(SOURCE_MEMBERS))
def test_sources_resolve_as_the_shared_fixture_pins(
    member: dict[str, Any],
    case: dict[str, Any],
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    write_fixture_files(tmp_path, case)
    monkeypatch.chdir(tmp_path)
    connect_env(monkeypatch, case.get("env", {}))
    if "search" in case:
        serve_connect(monkeypatch, connect_fixture_server({}, search=case["search"])[0])
    expected = case["expected"]
    if expected.get("error"):
        with pytest.raises((ValueError, LookupError)):
            resolve_trajectory_source(case["source"])
        return
    resolved = resolve_trajectory_source(case["source"])
    if expected["kind"] == "local":
        assert isinstance(resolved, LocalSource)
    else:
        assert isinstance(resolved, ConnectSource)
        assert (resolved.guid, resolved.client.server) == (
            expected["guid"],
            expected["server"],
        )
        resolved.client.close()


def test_several_registered_servers_are_named_when_none_is_chosen(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write_servers(
        [
            _server("a", "https://one.example.com"),
            _server("b", "https://two.example.com"),
        ]
    )
    monkeypatch.chdir(tmp_path)
    connect_env(monkeypatch, {})

    with pytest.raises(ValueError, match="Registered Connect servers") as raised:
        resolve_trajectory_source(GUID)

    assert "https://one.example.com, https://two.example.com" in str(raised.value)


def test_a_guid_source_uses_the_one_registered_server(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    _write_servers([_server("a", "https://one.example.com")])
    monkeypatch.chdir(tmp_path)
    connect_env(monkeypatch, {})

    resolved = resolve_trajectory_source(GUID)

    assert isinstance(resolved, ConnectSource)
    assert resolved.client.server == "https://one.example.com"
    resolved.client.close()


@pytest.mark.parametrize(("member", "case"), cases(("enough", "enough_ancestry")))
def test_paging_stops_as_the_shared_fixture_pins(
    member: dict[str, Any], case: dict[str, Any]
) -> None:
    enough = enough_trace_lines(
        case["n"], _instant(case.get("since")), _instant(case.get("until"))
    )
    lines: list[str] = []
    answers = []
    for line in case["lines"]:
        lines.append(line if isinstance(line, str) else fixture_line(line))
        answers.append(enough(lines))
    assert answers == case["expected"]


@_named("severed")
def test_severed_ancestry_matches_the_shared_fixture(case: dict[str, Any]) -> None:
    spans = parse_otlp_lines([fixture_line(case["spans"])])
    assert has_severed_ancestry(spans) is case["expected"]


def _trace_queries(seen: list[Any]) -> list[dict[str, str]]:
    return [
        dict(r.url.params)
        for r in seen
        if r.url.path.endswith(f"/content/{GUID}/traces")
    ]


@pytest.mark.parametrize(
    ("member", "case"), cases(("refetch", "fetch_once", "early_stop"))
)
def test_connect_reads_match_the_shared_fixture(
    member: dict[str, Any], case: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    connect_env(monkeypatch, {"CONNECT_SERVER": "https://connect.example.com"})
    route, seen = connect_fixture_server(case["server"])
    serve_connect(monkeypatch, route)

    result, notices = read_case(
        lambda: trajectory_read(
            GUID,
            n=case.get("n"),
            since=_instant(case.get("since")),
            until=_instant(case.get("until")),
        )
    )

    assert _trace_queries(seen) == case["trace_queries"]
    assert notices == case.get("notice", [])
    assert_trajectories(result, case["trajectories"])


_EMPTY = {"version": "2026.09.0", "traces": [], "jobs": []}
_HINTS = {"content": CONTENT_TRACING_HINT, "server": SERVER_TRACING_HINT}


def _serve_empty_read(monkeypatch: pytest.MonkeyPatch, case: dict[str, Any]) -> None:
    connect_env(monkeypatch, {"CONNECT_SERVER": "https://connect.example.com"})
    route, _ = connect_fixture_server(
        _EMPTY, content=case["content"], settings=case["settings"]
    )
    serve_connect(monkeypatch, route)


@_named("empty_read")
def test_an_empty_read_reports_as_the_shared_fixture_pins(
    case: dict[str, Any], monkeypatch: pytest.MonkeyPatch
) -> None:
    _serve_empty_read(monkeypatch, case)

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        result = trajectory_read(GUID)

    message = CONNECT["empty_read"]["message"]
    hints = [_HINTS[hint] for hint in case["hints"]]
    expected = [" ".join([message, *hints])] if hints else []
    assert [str(w.message) for w in caught] == expected
    assert result == {}


def test_an_empty_read_warning_points_at_the_caller(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    (case,) = [
        c for c in CONNECT["empty_read"]["cases"] if c["name"] == "content tracing off"
    ]
    _serve_empty_read(monkeypatch, case)

    with pytest.warns(UserWarning) as caught:
        trajectory_read(GUID)

    assert [w.filename for w in caught] == [__file__]


def test_a_connect_read_closes_its_client(monkeypatch: pytest.MonkeyPatch) -> None:
    connect_env(monkeypatch, {"CONNECT_SERVER": "https://connect.example.com"})
    route, _ = connect_fixture_server(_EMPTY, search=[{"results": [], "total": 1}])
    clients = serve_connect(monkeypatch, route)

    trajectory_read(GUID)
    with pytest.raises(LookupError):
        trajectory_read("https://connect.example.com/content/missing")

    assert len(clients) == 2
    assert all(client.is_closed for client in clients)
