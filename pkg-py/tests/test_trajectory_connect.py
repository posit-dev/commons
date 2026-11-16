"""Tests for reading trajectories from Posit Connect.

The cases live in ``tests/shared/trajectories/connect.json``, and the R suite
runs the same cases, so a case belongs in the fixture rather than here. This
module adds only what the fixture cannot pin.
"""

import json
import logging
import os
import sys
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import pytest

from commons._connect import FROM_PAD, TO_PAD, normalize_server, window_param
from commons._trajectory._deployment import (
    find_deployment,
    registered_connect_servers,
)
from commons._trajectory._source import (
    content_url_guid,
    content_vanity_url,
    is_content_guid,
)
from tests._shared import load_shared_fixture

CONNECT = load_shared_fixture("trajectories/connect")
GUID = "ea3c1445-cb71-42df-a2f2-bdb18874ef41"
PARSE_MEMBERS = ("content_guid", "content_url", "vanity_url", "window_param")
RECORD_MEMBERS = ("record_search", "record_fields")


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


def test_every_member_is_run() -> None:
    assert set(CONNECT) - {"description"} == {*PARSE_MEMBERS, *RECORD_MEMBERS}


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


def test_a_python_record_without_a_content_url_is_skipped(tmp_path: Path) -> None:
    record = _python_record(app_url="https://me.shinyapps.io/app/")
    _write_python_record(tmp_path / "rsconnect-python" / "app.json", record)

    assert find_deployment(tmp_path) is None


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


def _write_servers(entries: list[dict[str, str]]) -> None:
    metadata = pytest.importorskip("rsconnect.metadata")
    directory = Path(metadata.config_dirname())
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


def test_no_registered_servers_without_rsconnect_python(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    _write_servers([_server("connect", "https://connect.example.com")])
    monkeypatch.setitem(sys.modules, "rsconnect", None)
    monkeypatch.setitem(sys.modules, "rsconnect.metadata", None)

    assert registered_connect_servers() == []
