"""A Posit Connect API client, covering what commons needs from Connect.

Connect gives running content an ephemeral owner-scoped ``CONNECT_API_KEY``
(``Applications.DefaultAPIKeyEnv``, on by default), so content can act on its
own behalf without a publisher configuring anything.
``pkg-r/R/connect.R`` is its counterpart.
"""

from __future__ import annotations

import os
import warnings
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from typing import Any, Self

import httpx

__all__ = [
    "ConnectClient",
    "ConnectError",
    "connect_content_guid",
    "is_connect_runtime",
    "share_trajectory_access",
]

# Connect pages a prefix search over users; a short page is the last one.
_USER_PAGE_SIZE = 500

# What Connect's permissions API calls the level that can read traces. It
# rejects "editor", which is what the level is called everywhere else.
_TRACE_ACCESS_ROLE = "owner"

# Usernames this process has already granted, keyed by content. A grant is
# durable, and an agent is typically built once per session, so re-issuing the
# API calls on every one buys nothing.
_GRANTED: set[tuple[str, str]] = set()


def is_connect_runtime() -> bool:
    """Is this process running as content on Posit Connect?"""
    return os.environ.get("POSIT_PRODUCT") == "CONNECT" or bool(
        os.environ.get("CONNECT_CONTENT_GUID")
    )


def connect_content_guid() -> str:
    """This content's GUID, or an empty string when it has none."""
    return os.environ.get("CONNECT_CONTENT_GUID", "")


class ConnectError(RuntimeError):
    """A Posit Connect API request failed, or answered with nonsense.

    ``status_code`` is ``None`` when there is no failing status: the request
    never got a response, or the response had a shape commons cannot read.
    """

    def __init__(self, message: str, *, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


class ConnectClient:
    """Authenticated access to one Posit Connect server's v1 API.

    Use it as a context manager, or call ``close()``, to release the HTTP
    client it creates. A client passed as ``http`` stays open.
    """

    def __init__(
        self, server: str, api_key: str, *, http: httpx.Client | None = None
    ) -> None:
        self.server = normalize_server(server)
        self.api_key = api_key
        self._owns_http = http is None
        self._http = httpx.Client() if http is None else http

    def close(self) -> None:
        if self._owns_http:
            self._http.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    @classmethod
    def from_env(cls, *, http: httpx.Client | None = None) -> ConnectClient:
        server = os.environ.get("CONNECT_SERVER", "")
        api_key = os.environ.get("CONNECT_API_KEY", "")
        if not server:
            raise ValueError(
                "Set the CONNECT_SERVER environment variable to your Posit "
                "Connect server URL."
            )
        if not api_key:
            raise ValueError(
                "Set the CONNECT_API_KEY environment variable to a Posit "
                "Connect API key."
            )
        return cls(server, api_key, http=http)

    def request(
        self,
        method: str,
        *path: str,
        params: dict[str, Any] | None = None,
        json: Any = None,
    ) -> httpx.Response:
        """Perform a request against ``/__api__/v1/<path>``.

        Raises ``ConnectError`` when the request fails in transit or the
        status is anything other than 2xx.
        """
        url = httpx.URL("/".join((self.server, "__api__", "v1", *path)))
        # Messages name the path only: the request carries the API key in a
        # header, and a message can reach a log or a bug report.
        try:
            response = self._http.request(
                method,
                url,
                params=params,
                json=json,
                headers={"Authorization": f"Key {self.api_key}"},
            )
        except httpx.RequestError as error:
            raise ConnectError(
                f"Could not reach Posit Connect for {method} {url.path}: "
                f"{type(error).__name__}"
            ) from error
        if not response.is_success:
            raise ConnectError(
                f"Posit Connect returned {response.status_code} for "
                f"{method} {url.path}",
                status_code=response.status_code,
            )
        return response


def normalize_server(server: str) -> str:
    """Reduce the forms a publisher might paste to one base URL."""
    return server.rstrip("/").removesuffix("/__api__").rstrip("/")


def share_trajectory_access(
    usernames: Sequence[str], *, client: ConnectClient | None = None
) -> None:
    """Give `usernames` access to this content's trajectories.

    Reading traces needs editor-level access, so these users are added as
    collaborators on the content. That is a wider grant than access to the
    traces alone.

    A grant is durable and agent construction should not fail over one, so any
    failure, including a Connect outage, warns and leaves the rest of the list
    ungranted.
    """
    check_usernames(usernames)
    if not usernames:
        return
    if not is_connect_runtime():
        warnings.warn(
            "share_with only applies when running on Posit Connect. Ignoring it.",
            stacklevel=2,
        )
        return

    guid = connect_content_guid()
    # Fold case before deduplicating: Connect matches usernames that way, so
    # ["ada", "ADA"] is one user and granting twice makes a second request
    # against a permissions snapshot that no longer reflects the first.
    pending = list(
        dict.fromkeys(
            username.lower()
            for username in usernames
            if (guid, username.lower()) not in _GRANTED
        )
    )
    if not pending:
        return

    try:
        client = ConnectClient.from_env() if client is None else client
        existing = collaborator_principals(client, guid)
        for username in pending:
            principal = user_guid(client, username)
            if principal not in existing:
                add_collaborator(client, guid, principal)
                existing.add(principal)
            _GRANTED.add((guid, username))
    except (ConnectError, LookupError, ValueError, httpx.HTTPError) as error:
        warnings.warn(
            f"Could not share trajectory access. {error}",
            stacklevel=2,
        )


def check_usernames(usernames: Sequence[str]) -> None:
    # Require a real sequence. A bare string is one, and would grant access a
    # letter at a time; a generator is not, and validating it would consume it
    # so the grant loop saw nothing and quietly granted nobody.
    if (
        isinstance(usernames, str)
        or not isinstance(usernames, Sequence)
        or not all(isinstance(username, str) for username in usernames)
    ):
        raise TypeError("share_with must be a sequence of Posit Connect usernames.")


@contextmanager
def unexpected_shape(what: str) -> Iterator[None]:
    """Report a well-formed response commons cannot read as a Connect failure.

    A 200 carrying the wrong shape is still a failure, and callers here treat
    every Connect failure as a warning rather than an error.
    """
    try:
        yield
    except (KeyError, TypeError, AttributeError) as error:
        raise ConnectError(
            f"Posit Connect returned an unexpected {what} response."
        ) from error


def user_guid(client: ConnectClient, username: str) -> str:
    """Find a user by username, paging through the prefix search."""
    page_number = 1
    while True:
        body = client.request(
            "GET",
            "users",
            params={
                "prefix": username,
                "page_size": _USER_PAGE_SIZE,
                "page_number": page_number,
            },
        ).json()
        with unexpected_shape("user search"):
            results = body["results"]
            matched = [
                user["guid"]
                for user in results
                if user["username"].lower() == username.lower()
            ]
            # Checked here rather than at the caller: a guid flows into a set
            # membership test, and a non-string one raises on hashing long
            # after the response that produced it was read.
            if not all(isinstance(guid, str) for guid in matched):
                raise TypeError("guid")
        if matched:
            return matched[0]
        if len(results) < _USER_PAGE_SIZE:
            raise LookupError(f"No Posit Connect user with username {username!r}.")
        page_number += 1


def collaborator_principals(client: ConnectClient, guid: str) -> set[str]:
    """Who already holds the role that can read this content's traces.

    A lesser permission does not count. Someone the app was shared with holds
    the viewer role, which carries no trace access, and skipping them because
    they appear in the permissions list would leave them unable to read
    anything while `share_with` reported nothing amiss.
    """
    permissions = client.request("GET", "content", guid, "permissions").json()
    with unexpected_shape("permissions"):
        # An object, empty or not, is not a permission list. Filtering one
        # yields nothing, which reads as "nobody has access" and grants on the
        # strength of a response commons could not read.
        if not isinstance(permissions, list):
            raise TypeError(type(permissions).__name__)
        return {
            permission["principal_guid"]
            for permission in permissions
            if permission.get("role") == _TRACE_ACCESS_ROLE
        }


def add_collaborator(client: ConnectClient, guid: str, principal: str) -> None:
    """Grant the level that can read traces, whatever Connect calls it."""
    client.request(
        "POST",
        "content",
        guid,
        "permissions",
        json={
            "principal_guid": principal,
            "principal_type": "user",
            "role": _TRACE_ACCESS_ROLE,
            "send_email": False,
        },
    )
