"""The Posit Connect API client: runtime detection, credentials, requests.

commons needs Connect for two things on the write side, turning on content
observability and granting collaborators access to traces. Both go through
this client. ``pkg-r/R/connect.R`` is its counterpart, and the behaviour a
publisher can observe, the variables read, the server forms accepted and the
URLs requests land on, is pinned for both in ``tests/shared/connect.json``.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from typing import Any

import httpx
import pytest

from commons._connect import (
    MINIMUM_TRACING_VERSION,
    ConnectClient,
    ConnectError,
    connect_content_guid,
    content,
    enable_otel,
    is_connect_runtime,
    parse_connect_version,
    server_settings,
    version_is_older,
)

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("connect")
ENVIRONMENT: dict[str, str] = SPEC["environment"]
NORMALIZATION: list[dict[str, Any]] = SPEC["server_normalization"]["cases"]
DETECTION: list[dict[str, Any]] = SPEC["runtime_detection"]["cases"]
API_REQUEST: dict[str, Any] = SPEC["api_request"]
OBSERVABILITY: dict[str, Any] = SPEC["observability"]
SETTINGS_CASES: list[dict[str, Any]] = OBSERVABILITY["server_settings"]["cases"]

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
