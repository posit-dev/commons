"""The Posit Connect API client: runtime detection, credentials, requests.

commons needs Connect for two things on the write side, turning on content
observability and granting collaborators access to traces. Both go through
this client. ``pkg-r/R/connect.R`` is its counterpart, and the behaviour a
publisher can observe, the variables read, the server forms accepted and the
URLs requests land on, is pinned for both in ``tests/shared/connect.json``.
"""

from __future__ import annotations

import json
from typing import Any

import httpx
import pytest

from commons._connect import (
    ConnectClient,
    ConnectError,
    connect_content_guid,
    is_connect_runtime,
)

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("connect")
ENVIRONMENT: dict[str, str] = SPEC["environment"]
NORMALIZATION: list[dict[str, Any]] = SPEC["server_normalization"]["cases"]
DETECTION: list[dict[str, Any]] = SPEC["runtime_detection"]["cases"]
API_REQUEST: dict[str, Any] = SPEC["api_request"]

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


def test_a_failure_does_not_disclose_the_api_key() -> None:
    # The key is an ephemeral owner-scoped credential; a traceback that
    # reaches a log or an issue report must not carry it.
    client, _ = client_recording(status=500)

    with pytest.raises(ConnectError) as raised:
        client.request("GET", "content", GUID)

    assert "the-api-key" not in str(raised.value)
    assert "the-api-key" not in repr(raised.value)
