"""The Posit Connect API client: runtime detection, credentials, requests.

commons needs Connect for two things on the write side, turning on content
observability and granting collaborators access to traces. Both go through
this client. ``pkg-r/R/connect.R`` is its counterpart, and the behaviour a
publisher can observe, the variables read, the server forms accepted and the
URLs requests land on, is pinned for both in ``tests/shared/connect.json``.
"""

from __future__ import annotations

import json
import re
import threading
from collections.abc import Callable, Iterator
from contextlib import contextmanager
from typing import Any

import httpx
import pytest

from commons._connect import (
    LEGACY_TRACE_STORE_BEFORE,
    MINIMUM_TRACING_VERSION,
    TRACE_PAGE_SIZE,
    ConnectClient,
    ConnectError,
    connect_content_guid,
    connect_trace_lines,
    content,
    enable_otel,
    is_connect_runtime,
    parse_connect_version,
    server_settings,
    vanity_guid,
    version_is_older,
)

from ._connect_fake import connect_fixture_server
from ._shared import load_shared_fixture
from ._trajectories import _instant

SPEC = load_shared_fixture("connect")
ENVIRONMENT: dict[str, str] = SPEC["environment"]
NORMALIZATION: list[dict[str, Any]] = SPEC["server_normalization"]["cases"]
DETECTION: list[dict[str, Any]] = SPEC["runtime_detection"]["cases"]
API_REQUEST: dict[str, Any] = SPEC["api_request"]
OBSERVABILITY: dict[str, Any] = SPEC["observability"]
SETTINGS_CASES: list[dict[str, Any]] = OBSERVABILITY["server_settings"]["cases"]
TRACES: dict[str, Any] = SPEC["traces"]
TRACE_GROUPS = ("pages", "stores", "fallback", "access")
TRACE_CASES = [
    pytest.param(case, id=f"{group}: {case['name']}")
    for group in TRACE_GROUPS
    for case in TRACES[group]["cases"]
]
VANITY_SEARCH: dict[str, Any] = SPEC["vanity_search"]

CONNECT_ENV = (
    ENVIRONMENT["product"],
    ENVIRONMENT["content_guid"],
    ENVIRONMENT["server"],
    ENVIRONMENT["api_key"],
)
GUID = "01234567-89ab-cdef-0123-456789abcdef"


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in CONNECT_ENV:
        monkeypatch.delenv(name, raising=False)


def client_recording(
    *,
    server: str = "https://connect.example.com",
    status: int = 200,
    json: object = None,
) -> tuple[ConnectClient, list[httpx.Request]]:
    """A client whose requests are captured instead of sent."""
    seen: list[httpx.Request] = []

    def record(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(status, json=json)

    http = httpx.Client(transport=httpx.MockTransport(record))
    return ConnectClient(server, "the-api-key", http=http), seen


def test_the_shared_fixture_carries_the_cases_it_promises() -> None:
    # A truncated fixture would collect fewer parametrized cases and the
    # suite would still pass, so pin what the tables have to contain.
    assert {case["expected"] for case in DETECTION} == {True, False}
    assert len(NORMALIZATION) >= 2
    assert len(API_REQUEST["cases"]) >= 1
    assert {case["warns"] for case in SETTINGS_CASES} == {"version", "disabled", None}
    assert all(TRACES[group]["cases"] for group in TRACE_GROUPS)
    assert VANITY_SEARCH["cases"]
    assert {case["outcome"] for case in OBSERVABILITY["enable"]["cases"]} == {
        "toggled",
        "already_on",
        "failed",
    }


@pytest.mark.parametrize("case", DETECTION, ids=lambda case: case["name"])
def test_connect_runtime_detection_matches_the_shared_fixture(
    monkeypatch: pytest.MonkeyPatch, case: dict[str, Any]
) -> None:
    for name, value in case["env"].items():
        if value is not None:
            monkeypatch.setenv(name, value)

    assert is_connect_runtime() is case["expected"]


def test_content_guid_is_empty_off_connect() -> None:
    assert connect_content_guid() == ""


def test_content_guid_comes_from_the_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(ENVIRONMENT["content_guid"], GUID)

    assert connect_content_guid() == GUID


def test_credentials_are_read_from_the_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # Connect gives running content an ephemeral owner-scoped key, which is
    # what lets commons act on the content's behalf without configuration.
    monkeypatch.setenv(ENVIRONMENT["server"], "https://connect.example.com")
    monkeypatch.setenv(ENVIRONMENT["api_key"], "the-api-key")

    client = ConnectClient.from_env()

    assert client.server == "https://connect.example.com"
    assert client.api_key == "the-api-key"


@pytest.mark.parametrize("case", NORMALIZATION, ids=lambda case: case["name"])
def test_server_normalization_matches_the_shared_fixture(
    monkeypatch: pytest.MonkeyPatch, case: dict[str, Any]
) -> None:
    monkeypatch.setenv(ENVIRONMENT["server"], case["configured"])
    monkeypatch.setenv(ENVIRONMENT["api_key"], "the-api-key")

    assert ConnectClient.from_env().server == case["expected"]


def test_a_missing_server_names_the_variable_to_set(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(ENVIRONMENT["api_key"], "the-api-key")

    with pytest.raises(ValueError, match=ENVIRONMENT["server"]):
        ConnectClient.from_env()


def test_a_missing_api_key_names_the_variable_to_set(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(ENVIRONMENT["server"], "https://connect.example.com")

    with pytest.raises(ValueError, match=ENVIRONMENT["api_key"]):
        ConnectClient.from_env()


@pytest.mark.parametrize("case", API_REQUEST["cases"], ids=lambda case: case["name"])
def test_request_urls_match_the_shared_fixture(case: dict[str, Any]) -> None:
    client, seen = client_recording(server=API_REQUEST["server"])

    client.request("GET", *case["path"])

    (request,) = seen
    assert str(request.url) == case["expected"]


def test_requests_carry_the_api_key() -> None:
    client, seen = client_recording()

    client.request("GET", "content", GUID)

    (request,) = seen
    assert request.headers["Authorization"] == "Key the-api-key"


def test_query_parameters_are_sent() -> None:
    client, seen = client_recording()

    client.request("GET", "users", params={"prefix": "ada", "page_number": 2})

    (request,) = seen
    assert request.url.params["prefix"] == "ada"
    assert request.url.params["page_number"] == "2"


def test_a_json_body_is_sent() -> None:
    client, seen = client_recording()

    client.request("PATCH", "content", GUID, json={"otel_enabled": True})

    (request,) = seen
    assert json.loads(request.read()) == {"otel_enabled": True}
    assert request.headers["Content-Type"] == "application/json"


def test_the_decoded_body_is_returned() -> None:
    client, _ = client_recording(json={"otel_enabled": False})

    assert client.request("GET", "content", GUID).json() == {"otel_enabled": False}


def test_a_failed_request_raises_with_the_status_and_the_url() -> None:
    client, _ = client_recording(status=403, json={"error": "not authorized"})

    with pytest.raises(ConnectError) as raised:
        client.request("GET", "content", GUID)

    assert raised.value.status_code == 403
    assert "403" in str(raised.value)
    assert f"/content/{GUID}" in str(raised.value)


def test_a_redirect_raises() -> None:
    # httpx does not follow redirects by default, so a 3xx means the
    # operation was not performed.
    client, _ = client_recording(status=307)

    with pytest.raises(ConnectError) as raised:
        client.request("PATCH", "content", GUID, json={"otel_enabled": True})

    assert raised.value.status_code == 307


def client_refusing() -> ConnectClient:
    """A client whose every request fails before reaching a server."""

    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    http = httpx.Client(transport=httpx.MockTransport(refuse))
    return ConnectClient("https://connect.example.com", "the-api-key", http=http)


def test_a_network_failure_raises_a_connect_error() -> None:
    # One exception type covers every way a request can fail, so callers
    # cannot catch the status failures and miss an outage.
    with pytest.raises(ConnectError) as raised:
        client_refusing().request("GET", "content", GUID)

    assert raised.value.status_code is None
    assert f"/content/{GUID}" in str(raised.value)


@pytest.mark.parametrize(
    "fail",
    [
        pytest.param(lambda: client_recording(status=500)[0], id="status"),
        pytest.param(client_refusing, id="network"),
    ],
)
def test_a_failure_does_not_disclose_the_api_key(
    fail: Callable[[], ConnectClient],
) -> None:
    # The key is an ephemeral owner-scoped credential; a traceback that
    # reaches a log or an issue report must not carry it.
    with pytest.raises(ConnectError) as raised:
        fail().request("GET", "content", GUID)

    assert "the-api-key" not in str(raised.value)
    assert "the-api-key" not in repr(raised.value)
    assert "the-api-key" not in repr(raised.value.__cause__)


def test_closing_releases_the_client_it_created() -> None:
    with ConnectClient("https://connect.example.com", "the-api-key") as client:
        pass

    with pytest.raises(RuntimeError, match="closed"):
        client.request("GET", "users")


def test_closing_leaves_a_caller_supplied_client_open() -> None:
    http = httpx.Client(transport=httpx.MockTransport(lambda _: httpx.Response(200)))

    with ConnectClient("https://connect.example.com", "the-api-key", http=http):
        pass

    assert not http.is_closed


def test_the_minimum_tracing_version_matches_the_shared_fixture() -> None:
    assert OBSERVABILITY["minimum_version"] == MINIMUM_TRACING_VERSION


def test_server_settings_requests_the_unversioned_url_from_the_shared_fixture() -> None:
    client, seen = client_recording(
        server="https://connect.example.com", json={"version": "2026.09.0"}
    )

    assert server_settings(client) == {"version": "2026.09.0"}

    (request,) = seen
    spec = OBSERVABILITY["server_settings"]
    assert request.method == spec["method"]
    assert str(request.url) == spec["url"].replace(
        "{server}", "https://connect.example.com"
    )
    assert request.headers["Authorization"] == "Key the-api-key"


def test_server_settings_rejects_an_answer_that_is_not_an_object() -> None:
    client, _ = client_recording(json="unexpected response")

    with pytest.raises(ConnectError, match="unexpected"):
        server_settings(client)


def test_content_reads_the_shared_endpoint() -> None:
    client, seen = client_recording(json={"otel_enabled": False})
    spec = OBSERVABILITY["enable"]["read"]

    assert content(client, GUID) == {"otel_enabled": False}

    (request,) = seen
    assert request.method == spec["method"]
    assert request.url.path == "/__api__/v1/" + "/".join(spec["endpoint"]).replace(
        "{guid}", GUID
    )


def test_content_rejects_an_answer_that_is_not_an_object() -> None:
    client, _ = client_recording(json=[])

    with pytest.raises(ConnectError, match="unexpected"):
        content(client, GUID)


def test_enable_otel_sends_the_shared_write() -> None:
    client, seen = client_recording(json={})
    spec = OBSERVABILITY["enable"]["write"]

    enable_otel(client, GUID)

    (request,) = seen
    assert request.method == spec["method"]
    assert request.url.path == "/__api__/v1/" + "/".join(spec["endpoint"]).replace(
        "{guid}", GUID
    )
    assert json.loads(request.content) == spec["body"]


@pytest.mark.parametrize(
    "case",
    [case for case in SETTINGS_CASES if isinstance(case["settings"], dict)],
    ids=lambda case: case["name"],
)
def test_the_version_comparison_matches_the_shared_cases(
    case: dict[str, Any],
) -> None:
    version = parse_connect_version(case["settings"].get("version"))

    too_old = version is not None and version_is_older(version, MINIMUM_TRACING_VERSION)

    assert too_old is (case["warns"] == "version")


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("2026.09.0", (2026, 9, 0)),
        ("v2026.10.0-dev+12-gabc123", (2026, 10, 0)),
        ("2026.09", (2026, 9)),
        ("unknown", None),
        (None, None),
        (2026, None),
    ],
)
def test_parse_connect_version(text: object, expected: tuple[int, ...] | None) -> None:
    assert parse_connect_version(text) == expected


def test_a_malformed_server_url_is_a_connect_error() -> None:
    client = ConnectClient("https://connect.example.com:notaport", "the-api-key")

    with pytest.raises(ConnectError, match="GET /__api__/v1/content"):
        client.request("GET", "content")


def test_from_env_prefers_the_given_server(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(ENVIRONMENT["server"], "https://connect.example.com")
    monkeypatch.setenv(ENVIRONMENT["api_key"], "the-api-key")

    client = ConnectClient.from_env(server="https://other.example.com/__api__")

    assert client.server == "https://other.example.com"


@contextmanager
def _trace_client(
    route: Callable[[httpx.Request], httpx.Response],
    server: str = "https://connect.example.com",
) -> Iterator[ConnectClient]:
    with httpx.Client(transport=httpx.MockTransport(route)) as http:
        yield ConnectClient(server, "key", http=http)


def _request_key(request: httpx.Request) -> tuple[str, tuple[tuple[str, str], ...]]:
    path = re.sub(rf"^/__api__/v1/content/{GUID}/", "", request.url.path)
    return path, tuple(sorted(request.url.params.multi_items()))


def _fixture_key(request: dict[str, Any]) -> tuple[str, tuple[tuple[str, str], ...]]:
    return request["path"], tuple(sorted(request["query"].items()))


@pytest.mark.parametrize("case", TRACE_CASES)
def test_trace_lines_match_the_shared_fixture(case: dict[str, Any]) -> None:
    route, seen = connect_fixture_server(case["server"])

    def read() -> list[str]:
        with _trace_client(route) as client:
            return connect_trace_lines(
                client,
                GUID,
                since=_instant(case.get("since")),
                until=_instant(case.get("until")),
                enough=(lambda lines: True) if case.get("enough") else None,
            )

    if case.get("error") == "access":
        with pytest.raises(ConnectError, match=re.escape(TRACES["access_error"])):
            read()
    elif case.get("error") == "missing":
        with pytest.raises(
            ConnectError, match=re.escape(TRACES["missing_error"])
        ) as raised:
            read()
        assert GUID in str(raised.value)
        assert "https://connect.example.com" in str(raised.value)
    elif case.get("error") == "failed":
        with pytest.raises(ConnectError) as raised:
            read()
        assert not str(raised.value).startswith(TRACES["access_error"])
    else:
        assert read() == case["lines"]
        assert sorted(_request_key(r) for r in seen) == sorted(
            _fixture_key(r) for r in case["requests"]
        )


@pytest.mark.parametrize("case", VANITY_SEARCH["cases"], ids=lambda case: case["name"])
def test_vanity_search_matches_the_shared_fixture(case: dict[str, Any]) -> None:
    route, seen = connect_fixture_server({}, search=case["pages"])
    url = f"{case['server']}/content/{case['query']}"

    with _trace_client(route, case["server"]) as client:
        if case["expected"] is None:
            with pytest.raises(LookupError, match="Can't find content"):
                vanity_guid(client, url, case["query"])
        else:
            assert vanity_guid(client, url, case["query"]) == case["expected"]

    assert [int(r.url.params["page_number"]) for r in seen] == case["page_numbers"]
    request = VANITY_SEARCH["request"]
    first = seen[0]
    assert first.url.path.endswith("/__api__/v1/" + "/".join(request["path"]))
    assert {k: first.url.params[k] for k in request["query"]} == request["query"]
    assert first.url.params["q"] == case["query"]


def test_the_trace_page_size_and_store_version_match_the_shared_fixture() -> None:
    assert TRACE_PAGE_SIZE == TRACES["page_size"]
    assert LEGACY_TRACE_STORE_BEFORE == TRACES["legacy_store_before"]


def test_an_access_error_names_the_share_with_argument() -> None:
    route, _ = connect_fixture_server({"traces": {"status": 403}})

    with (
        _trace_client(route) as client,
        pytest.raises(ConnectError, match="share_with") as raised,
    ):
        connect_trace_lines(client, GUID)

    assert raised.value.status_code == 403
    cause = raised.value.__cause__
    assert isinstance(cause, ConnectError)
    assert cause.status_code == 403


@pytest.mark.parametrize("version", ["2026.06.1", "2026.09.0"])
def test_a_response_without_a_total_ends_the_read_after_one_page(
    version: str,
) -> None:
    lines = ["line1", "line2", "line3"]
    seen: list[httpx.Request] = []

    def route(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if request.url.path.endswith("/jobs"):
            return httpx.Response(200, json=[])
        offset = int(request.url.params["offset"])
        body = "".join(line + "\n" for line in lines[offset : offset + 2])
        return httpx.Response(
            200, headers={"Server": f"Posit Connect v{version}"}, text=body
        )

    with _trace_client(route) as client:
        assert connect_trace_lines(client, GUID) == ["line1", "line2"]
    assert [r.url.path.endswith("/traces") for r in seen].count(True) == 1


@pytest.mark.parametrize("jobs", [{"key": "job"}, [{"id": 1}, "job"], "not json"])
def test_malformed_jobs_read_as_no_jobs(jobs: object) -> None:
    seen: list[httpx.Request] = []

    def route(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        if request.url.path.endswith("/jobs"):
            if jobs == "not json":
                return httpx.Response(200, text="not json")
            return httpx.Response(200, json=jobs)
        return httpx.Response(
            200,
            headers={"Server": "Posit Connect v2026.09.0", "X-Total-Count": "1"},
            text="current\n",
        )

    with _trace_client(route) as client:
        assert connect_trace_lines(client, GUID) == ["current"]
    assert [r.url.path.rsplit("/", 1)[-1] for r in seen] == ["traces", "jobs"]


def test_a_failed_job_request_cancels_the_queued_ones() -> None:
    # job1 fails at once while the other running requests wait for `release`,
    # which a timer sets after the failure. The read must not return while they
    # run, since the caller closes the client it shares with them.
    jobs = [{"key": f"job{i}"} for i in range(100)]
    release = threading.Event()
    lock = threading.Lock()
    running = 0
    seen: list[httpx.Request] = []

    def route(request: httpx.Request) -> httpx.Response:
        nonlocal running
        seen.append(request)
        path = request.url.path
        if path.endswith("/jobs"):
            return httpx.Response(200, json=jobs)
        if path.endswith("/jobs/job1/traces"):
            return httpx.Response(500)
        if "/jobs/" in path:
            with lock:
                running += 1
            release.wait(timeout=10)
            with lock:
                running -= 1
            return httpx.Response(200, headers={"X-Total-Count": "1"}, text="x\n")
        return httpx.Response(200, headers={"X-Total-Count": "0"}, text="")

    timer = threading.Timer(0.2, release.set)
    timer.start()
    try:
        with _trace_client(route) as client, pytest.raises(ConnectError):
            connect_trace_lines(client, GUID)
        assert running == 0
    finally:
        release.set()
        timer.cancel()
    # Only the requests already running when job1 failed are sent.
    job_requests = [r for r in seen if "/jobs/" in r.url.path]
    assert len(job_requests) < len(jobs) // 2
