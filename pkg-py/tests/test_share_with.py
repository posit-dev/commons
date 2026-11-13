"""Granting Connect users access to this content's trajectories.

Reading traces needs editor-level access, which Connect's permissions API
grants through the collaborator role. ``share_trajectory_access()`` in
``pkg-r/R/tracing.R`` is the counterpart, and what a grant does is pinned for
both in ``tests/shared/connect.json``.
"""

from __future__ import annotations

import json
import warnings
from typing import Any

import httpx
import pytest

from commons._connect import ConnectClient, share_trajectory_access

from ._shared import load_shared_fixture

SPEC = load_shared_fixture("connect")
GRANT: dict[str, Any] = SPEC["collaborator_grant"]
SHARING: list[dict[str, Any]] = SPEC["sharing"]["cases"]
GUID = "01234567-89ab-cdef-0123-456789abcdef"
DIRECTORY = {"ada": "guid-ada", "grace": "guid-grace"}


@pytest.fixture(autouse=True)
def _on_connect(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CONNECT_CONTENT_GUID", GUID)
    monkeypatch.setenv("CONNECT_SERVER", "https://connect.example.com")
    monkeypatch.setenv("CONNECT_API_KEY", "the-api-key")


@pytest.fixture(autouse=True)
def _forget_grants() -> None:
    from commons import _connect

    _connect._GRANTED.clear()


def connect_double(
    *,
    users: dict[str, str] | None = None,
    permitted: Any = None,
    refused: list[str] | None = None,
    fail: str | None = None,
) -> tuple[ConnectClient, list[httpx.Request]]:
    """A Connect server with the given users and existing permissions.

    A grant for a principal in `refused` gets the 400 Connect gives the
    content's owner.
    """
    users = DIRECTORY if users is None else users
    permitted = [] if permitted is None else permitted
    refused = [] if refused is None else refused
    seen: list[httpx.Request] = []
    page_size = 500

    def route(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        path = request.url.path
        if fail is not None and fail in path:
            return httpx.Response(500, json={"error": "boom"})
        if path.endswith("/permissions") and request.method == "GET":
            return httpx.Response(200, json=permitted)
        if path.endswith("/permissions"):
            if json.loads(request.read())["principal_guid"] in refused:
                return httpx.Response(400, json={"code": 74})
            return httpx.Response(200, json={})
        if path.endswith("/users"):
            prefix = request.url.params["prefix"].lower()
            page = int(request.url.params["page_number"])
            # Insertion order, not sorted: Connect promises no ordering for a
            # prefix search, and sorting would put an exact match ahead of the
            # longer names it prefixes, so paging could never be exercised.
            matches = [name for name in users if name.startswith(prefix)]
            # Connect pages a prefix search; a short page is the last one.
            start = (page - 1) * page_size
            window = matches[start : start + page_size]
            return httpx.Response(
                200,
                json={
                    "results": [
                        {"username": name, "guid": users[name]} for name in window
                    ]
                },
            )
        raise AssertionError(f"unexpected request to {path}")

    http = httpx.Client(transport=httpx.MockTransport(route))
    return ConnectClient("https://connect.example.com", "the-api-key", http=http), seen


def grants(seen: list[httpx.Request]) -> list[dict[str, Any]]:
    return [
        json.loads(request.read())
        for request in seen
        if request.method == "POST" and request.url.path.endswith("/permissions")
    ]


def test_the_shared_fixture_covers_a_grant_and_a_skip() -> None:
    assert {bool(case["expected"]) for case in SHARING} == {True, False}


def test_the_grant_matches_the_shared_fixture() -> None:
    client, seen = connect_double()

    share_trajectory_access(["ada"], client=client)

    (request,) = [request for request in seen if request.method == GRANT["method"]]
    expected = "/".join(
        ["/__api__/v1", *(part.replace("{guid}", GUID) for part in GRANT["endpoint"])]
    )
    assert request.url.path == expected
    assert json.loads(request.read()) == {"principal_guid": "guid-ada", **GRANT["body"]}


@pytest.mark.parametrize("case", SHARING, ids=lambda case: case["name"])
def test_who_gets_a_grant_matches_the_shared_fixture(case: dict[str, Any]) -> None:
    refused = case.get("refused", [])
    client, seen = connect_double(permitted=case["permitted"], refused=refused)

    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        share_trajectory_access(case["usernames"], client=client)

    granted = [grant["principal_guid"] for grant in grants(seen)]
    assert [guid for guid in granted if guid not in refused] == case["expected"]
    warned = any("Could not share" in str(warning.message) for warning in caught)
    assert warned == case.get("warns", False)


def test_a_username_handled_once_is_not_looked_up_again() -> None:
    # Agents are typically built per session, and a durable grant does not
    # need re-issuing on every one.
    client, seen = connect_double()

    share_trajectory_access(["ada"], client=client)
    before = len(seen)
    share_trajectory_access(["ADA"], client=client)

    assert len(seen) == before


def test_a_username_repeated_in_one_call_is_looked_up_once() -> None:
    # The grant outcome is already right without this, because the second
    # attempt sees the first in the permissions set. What it saves is the
    # redundant round trip to resolve the same user again.
    client, seen = connect_double()

    share_trajectory_access(["ada", "ADA"], client=client)

    lookups = [request for request in seen if request.url.path.endswith("/users")]
    assert len(lookups) == 1


def test_a_user_beyond_the_first_page_of_matches_is_found() -> None:
    # The exact match has to sort after a full page of prefix matches, or the
    # first response contains it and paging is never exercised.
    users = {f"ada{index:03d}": f"guid-{index}" for index in range(500)}
    users["ada"] = "guid-ada"
    client, seen = connect_double(users=users)

    share_trajectory_access(["ada"], client=client)

    lookups = [request for request in seen if request.url.path.endswith("/users")]
    assert [request.url.params["page_number"] for request in lookups] == ["1", "2"]
    assert [grant["principal_guid"] for grant in grants(seen)] == ["guid-ada"]


def test_an_unknown_username_warns_rather_than_raising() -> None:
    # A grant is durable, so a failure is worth saying out loud but is not
    # worth failing agent construction over.
    client, seen = connect_double()

    with pytest.warns(UserWarning, match="mallory"):
        share_trajectory_access(["mallory"], client=client)

    assert grants(seen) == []


def test_a_refused_user_is_tried_again_next_time() -> None:
    # Only a grant that went through is remembered, so a refusal the
    # publisher fixes on Connect succeeds when the agent is next built.
    client, seen = connect_double(refused=["guid-ada"])

    with pytest.warns(UserWarning, match="'ada'"):
        share_trajectory_access(["ada"], client=client)
    before = len(grants(seen))
    with pytest.warns(UserWarning, match="'ada'"):
        share_trajectory_access(["ada"], client=client)

    assert len(grants(seen)) == before + 1


def test_a_server_failure_warns_rather_than_raising() -> None:
    client, _ = connect_double(fail="/permissions")

    with pytest.warns(UserWarning, match="Could not share"):
        share_trajectory_access(["ada"], client=client)


def test_a_network_failure_warns_rather_than_raising() -> None:
    # A Connect outage during agent construction must not take the agent down
    # with it: the grant is durable and can be reissued next time.
    def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    client = ConnectClient(
        "https://connect.example.com",
        "the-api-key",
        http=httpx.Client(transport=httpx.MockTransport(refuse)),
    )

    with pytest.warns(UserWarning, match="Could not share"):
        share_trajectory_access(["ada"], client=client)


def test_sharing_off_connect_warns_and_does_nothing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("CONNECT_CONTENT_GUID", raising=False)
    monkeypatch.delenv("POSIT_PRODUCT", raising=False)
    client, seen = connect_double()

    with pytest.warns(UserWarning, match="only applies when running on"):
        share_trajectory_access(["ada"], client=client)

    assert seen == []


def test_a_bare_string_is_rejected() -> None:
    # Iterating a string would grant access one letter at a time.
    client, _ = connect_double()

    with pytest.raises(TypeError, match="sequence of Posit Connect usernames"):
        share_trajectory_access("ada", client=client)  # type: ignore[arg-type]


def test_a_non_string_username_is_rejected() -> None:
    client, _ = connect_double()

    with pytest.raises(TypeError, match="sequence of Posit Connect usernames"):
        share_trajectory_access([1], client=client)  # type: ignore[list-item]


def test_sharing_with_nobody_makes_no_requests() -> None:
    client, seen = connect_double()

    share_trajectory_access([], client=client)

    assert seen == []


def test_a_malformed_permissions_response_warns_rather_than_raising() -> None:
    # A 200 with the wrong shape is still a failure to share, and the promise
    # is that sharing never takes agent construction down.
    def malformed(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[{"role": "owner"}])

    client = ConnectClient(
        "https://connect.example.com",
        "the-api-key",
        http=httpx.Client(transport=httpx.MockTransport(malformed)),
    )

    with pytest.warns(UserWarning, match="Could not share"):
        share_trajectory_access(["ada"], client=client)


def test_a_malformed_user_search_warns_rather_than_raising() -> None:
    def malformed(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/users"):
            return httpx.Response(200, json=["ada"])
        return httpx.Response(200, json=[])

    client = ConnectClient(
        "https://connect.example.com",
        "the-api-key",
        http=httpx.Client(transport=httpx.MockTransport(malformed)),
    )

    with pytest.warns(UserWarning, match="Could not share"):
        share_trajectory_access(["ada"], client=client)


def test_a_generator_of_usernames_is_rejected() -> None:
    # Validating one consumes it, and the grant loop would then see nothing
    # and quietly grant nobody.
    _, seen = connect_double()

    with pytest.raises(TypeError, match="sequence of Posit Connect usernames"):
        share_trajectory_access(name for name in ["ada"])  # type: ignore[arg-type]

    assert seen == []


def test_a_user_guid_that_is_not_a_string_warns() -> None:
    # The guid flows into a set membership test, so a list here raises on
    # hashing well after the response was read.
    def malformed(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/permissions"):
            return httpx.Response(200, json=[])
        return httpx.Response(200, json={"results": [{"username": "ada", "guid": []}]})

    client = ConnectClient(
        "https://connect.example.com",
        "the-api-key",
        http=httpx.Client(transport=httpx.MockTransport(malformed)),
    )

    with pytest.warns(UserWarning, match="Could not share"):
        share_trajectory_access(["ada"], client=client)


def test_a_client_created_from_the_environment_is_closed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, seen = connect_double()
    closed: list[bool] = []
    monkeypatch.setattr(client, "close", lambda: closed.append(True))
    monkeypatch.setattr(ConnectClient, "from_env", classmethod(lambda cls, **_: client))

    share_trajectory_access(["ada"])

    assert grants(seen)
    assert closed == [True]


def test_a_caller_supplied_client_is_left_open(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client, seen = connect_double()
    closed: list[bool] = []
    monkeypatch.setattr(client, "close", lambda: closed.append(True))

    share_trajectory_access(["ada"], client=client)

    assert grants(seen)
    assert closed == []
