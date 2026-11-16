"""A Posit Connect API client, covering what commons needs from Connect.

Connect gives running content an ephemeral owner-scoped ``CONNECT_API_KEY``
(``Applications.DefaultAPIKeyEnv``, on by default), so content can act on its
own behalf without a publisher configuring anything.
``pkg-r/R/connect.R`` is its counterpart.
"""

from __future__ import annotations

import os
import re
import warnings
from collections.abc import Callable, Iterator, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import contextmanager, nullcontext
from datetime import UTC, datetime, timedelta
from typing import Any, Self
from urllib.parse import unquote

import httpx

__all__ = [
    "FROM_PAD",
    "LEGACY_TRACE_STORE_BEFORE",
    "MINIMUM_TRACING_VERSION",
    "TO_PAD",
    "TRACE_ACCESS_MESSAGE",
    "TRACE_PAGE_SIZE",
    "ConnectClient",
    "ConnectError",
    "connect_content_guid",
    "connect_trace_lines",
    "content",
    "enable_otel",
    "is_connect_runtime",
    "normalize_connect_url",
    "parse_connect_version",
    "server_settings",
    "share_trajectory_access",
    "trace_access_error",
    "vanity_guid",
    "version_is_older",
    "window_param",
]

# The first Connect release that records trajectories, as Connect writes it.
MINIMUM_TRACING_VERSION = "2026.09.0"

_VERSION = re.compile(r"([0-9]+(?:\.[0-9]+){1,2})")

# The lines a traces request asks for.
TRACE_PAGE_SIZE = 1000

# The first Connect release with a second trace store beside each job's own.
LEGACY_TRACE_STORE_BEFORE = "2026.07.0"

TRACE_ACCESS_MESSAGE = (
    "Couldn't read this content's traces from Posit Connect. Reading traces "
    "requires editor access: the CONNECT_API_KEY user must own the content or "
    "be a collaborator. See the share_with argument of commons.Commons."
)

# Jobs whose trace pages are requested at once.
_JOB_WORKERS = 20

# The results a content search returns per page.
_SEARCH_PAGE_SIZE = 100

# How far each bound of a read's window is widened before it is sent.
FROM_PAD = timedelta(hours=-1)
TO_PAD = timedelta(seconds=1)

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
    def from_env(
        cls, *, server: str | None = None, http: httpx.Client | None = None
    ) -> ConnectClient:
        """A client for `server`, or CONNECT_SERVER, with CONNECT_API_KEY."""
        if server is None:
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
        versioned: bool = True,
    ) -> httpx.Response:
        """Perform a request against ``/__api__/v1/<path>``.

        ``versioned=False`` drops the ``v1``, for the few endpoints outside
        the versioned API.

        Raises ``ConnectError`` when the request fails in transit or the
        status is anything other than 2xx.
        """
        prefix = ("__api__", "v1") if versioned else ("__api__",)
        route = "/" + "/".join((*prefix, *path))
        # Messages name the path only: the request carries the API key in a
        # header, and a message can reach a log or a bug report.
        try:
            url = httpx.URL(self.server + route)
            response = self._http.request(
                method,
                url,
                params=params,
                json=json,
                headers={"Authorization": f"Key {self.api_key}"},
            )
        except (httpx.RequestError, httpx.InvalidURL) as error:
            raise ConnectError(
                f"Could not reach Posit Connect for {method} {route}: "
                f"{type(error).__name__}"
            ) from error
        if not response.is_success:
            raise ConnectError(
                f"Posit Connect returned {response.status_code} for "
                f"{method} {url.path}",
                status_code=response.status_code,
            )
        return response


def parse_connect_version(text: object) -> tuple[int, ...] | None:
    """The numeric version in a Connect version string, or ``None``.

    Reads the first ``major.minor`` or ``major.minor.patch`` in the text, so a
    development build such as ``v2026.10.0-dev+12-gabc123`` parses.
    """
    if not isinstance(text, str):
        return None
    match = _VERSION.search(text)
    if match is None:
        return None
    return tuple(int(part) for part in match.group(1).split("."))


def version_is_older(version: tuple[int, ...], minimum: str) -> bool:
    """Is `version` older than the version string `minimum`?

    A missing part counts as zero.
    """
    floor = tuple(int(part) for part in minimum.split("."))
    width = max(len(version), len(floor))
    padded = [(*parts, *([0] * (width - len(parts)))) for parts in (version, floor)]
    return padded[0] < padded[1]


def window_param(at: datetime | None, pad: timedelta) -> str | None:
    """A window bound as Connect's `from`, `to`, or `since` query value.

    None when there is no bound, or when padding takes it out of the range of
    datetime; the window is applied exactly after the read either way.
    """
    # Connect ignores a timestamp it cannot parse, so send UTC with a `Z`. The
    # pads keep the parent spans that start before the window. Pad in UTC:
    # arithmetic on an aware local time is wall-clock arithmetic.
    if at is None:
        return None
    try:
        padded = at.astimezone(UTC) + pad
    except OverflowError:
        return None
    return padded.strftime("%Y-%m-%dT%H:%M:%SZ")


def connect_trace_lines(
    client: ConnectClient,
    guid: str,
    *,
    since: datetime | None = None,
    until: datetime | None = None,
    enough: Callable[[Sequence[str]], bool] | None = None,
    page_size: int = TRACE_PAGE_SIZE,
) -> list[str]:
    """The content's trace lines, as OTLP JSON, newest first.

    `since` and `until` are sent padded, so the caller applies the window
    exactly. `enough(lines)` may stop the read early on an older server.
    """
    window = {
        key: value
        for key, value in (
            ("from", window_param(since, FROM_PAD)),
            ("to", window_param(until, TO_PAD)),
        )
        if value is not None
    }
    lines: list[str] = []
    offset = 0
    version: tuple[int, ...] | None = None
    while True:
        try:
            response = client.request(
                "GET",
                "content",
                guid,
                "traces",
                params={"limit": page_size, "offset": offset, **window},
            )
        except ConnectError as error:
            if error.status_code in (401, 403):
                raise trace_access_error(error) from error
            if error.status_code == 404:
                return _job_trace_lines(
                    client, guid, since=since, page_size=page_size, lines=[]
                )
            raise
        if version is None:
            version = parse_connect_version(response.headers.get("Server"))
        page = _page_lines(response)
        lines.extend(page)
        total = _total(response)
        offset += len(page)
        # Stopping early is safe only on a server with a single trace store.
        if (
            version is not None
            and version_is_older(version, LEGACY_TRACE_STORE_BEFORE)
            and lines
            and enough is not None
            and enough(lines)
        ):
            return lines
        if not page or total is None or offset >= total:
            break
    # Connect 2026.07 moved new traces without migrating the per-job files.
    if version is None or not version_is_older(version, LEGACY_TRACE_STORE_BEFORE):
        lines = _job_trace_lines(
            client, guid, since=since, page_size=page_size, lines=lines
        )
    return list(dict.fromkeys(lines))


def _job_trace_lines(
    client: ConnectClient,
    guid: str,
    *,
    since: datetime | None,
    page_size: int,
    lines: list[str],
) -> list[str]:
    """`lines`, then each job's trace lines, a page from each job in turn."""
    try:
        response = client.request("GET", "content", guid, "jobs")
    except ConnectError as error:
        if error.status_code in (401, 403):
            raise trace_access_error(error) from error
        raise
    try:
        jobs = response.json()
    except ValueError:
        jobs = []
    keys = [
        job["key"]
        for job in (jobs if isinstance(jobs, list) else [])
        if isinstance(job, dict) and isinstance(job.get("key"), str)
    ]
    lines = list(lines)
    if not keys:
        return lines
    params: dict[str, Any] = {"limit": page_size}
    since_param = window_param(since, FROM_PAD)
    if since_param is not None:
        params["since"] = since_param

    def job_page(key: str, offset: int) -> httpx.Response:
        return client.request(
            "GET",
            "content",
            guid,
            "jobs",
            key,
            "traces",
            params={**params, "offset": offset},
        )

    pending = [(key, 0) for key in keys]
    pool = ThreadPoolExecutor(max_workers=_JOB_WORKERS)
    try:
        while pending:
            futures = [pool.submit(job_page, key, offset) for key, offset in pending]
            # Fail on the first refused or failed request, whichever job it is.
            for future in as_completed(futures):
                error = future.exception()
                if not isinstance(error, ConnectError):
                    if error is None:
                        continue
                    raise error
                if error.status_code == 404:
                    continue
                if error.status_code in (401, 403):
                    raise trace_access_error(error) from error
                raise error
            unfinished: list[tuple[str, int]] = []
            for (key, offset), future in zip(pending, futures, strict=True):
                if future.exception() is not None:
                    continue
                page_response = future.result()
                page = _page_lines(page_response)
                lines.extend(page)
                total = _total(page_response)
                offset += len(page)
                if page and total is not None and offset < total:
                    unfinished.append((key, offset))
            pending = unfinished
    finally:
        # A failure leaves the queued requests unsent and returns without
        # waiting for the running ones.
        pool.shutdown(wait=False, cancel_futures=True)
    return lines


def _page_lines(response: httpx.Response) -> list[str]:
    return [line for line in response.text.split("\n") if line]


def _total(response: httpx.Response) -> int | None:
    value = response.headers.get("X-Total-Count")
    try:
        return int(value.strip())
    except (AttributeError, ValueError):
        return None


def trace_access_error(error: ConnectError) -> ConnectError:
    """The error for a refused traces request, which names what access it needs."""
    return ConnectError(TRACE_ACCESS_MESSAGE, status_code=error.status_code)


def normalize_connect_url(url: str) -> str:
    """A URL without its query, fragment, or trailing slashes, percent-decoded."""
    return unquote(re.sub(r"[?#].*$", "", url, flags=re.DOTALL).rstrip("/"))


def vanity_guid(client: ConnectClient, url: str, query: str) -> str:
    """The GUID of the content whose vanity URL is `query` on the client's server.

    The content search shows vanity URLs to anyone who can view the content,
    unlike the endpoint that lists them all. Raises LookupError when no
    result matches.
    """
    expected = normalize_connect_url(f"{client.server}/{query.lstrip('/')}")
    page_number = 1
    while True:
        response = client.request(
            "GET",
            "search",
            "content",
            params={
                "q": query,
                "include": "vanity_url",
                "page_number": page_number,
                "page_size": _SEARCH_PAGE_SIZE,
            },
        )
        try:
            body = response.json()
        except ValueError:
            body = None
        if not isinstance(body, dict):
            body = {}
        results = body.get("results")
        for result in results if isinstance(results, list) else []:
            if not isinstance(result, dict):
                continue
            vanity = result.get("vanity_url")
            guid = result.get("guid")
            if (
                isinstance(vanity, str)
                and isinstance(guid, str)
                and normalize_connect_url(vanity) == expected
            ):
                return guid
        total = body.get("total")
        if (
            not isinstance(total, int | float)
            or isinstance(total, bool)
            or page_number >= total
        ):
            break
        page_number += 1
    raise LookupError(
        f"Can't find content for the Connect vanity URL {url}. Check that the "
        "URL is correct and that your API key can access the content."
    )


def server_settings(client: ConnectClient) -> dict[str, Any]:
    """The server's settings, from an endpoint outside the versioned API."""
    settings = client.request("GET", "server_settings", versioned=False).json()
    with unexpected_shape("server settings"):
        if not isinstance(settings, dict):
            raise TypeError(type(settings).__name__)
    return settings


def content(client: ConnectClient, guid: str) -> dict[str, Any]:
    """The content item `guid`."""
    item = client.request("GET", "content", guid).json()
    with unexpected_shape("content"):
        if not isinstance(item, dict):
            raise TypeError(type(item).__name__)
    return item


def enable_otel(client: ConnectClient, guid: str) -> None:
    """Turn on Content Observability for the content item `guid`."""
    client.request("PATCH", "content", guid, json={"otel_enabled": True})


def normalize_server(server: str) -> str:
    """Reduce the forms a publisher might paste to one base URL."""
    return server.rstrip("/").removesuffix("/__api__").rstrip("/")


def share_trajectory_access(
    usernames: Sequence[str],
    *,
    client: ConnectClient | None = None,
    stacklevel: int = 2,
) -> None:
    """Give `usernames` access to this content's trajectories.

    Reading traces needs editor-level access, so these users are added as
    collaborators on the content. That is a wider grant than access to the
    traces alone.

    Named users need an account that can publish. Connect refuses the role to
    any other account, and to the content's owner.

    A grant is durable and agent construction should not fail over one, so any
    failure, including a Connect outage, warns. A user Connect refuses warns
    without stopping the grants to the users after it.
    """
    check_usernames(usernames)
    if not usernames:
        return
    if not is_connect_runtime():
        warnings.warn(
            "share_with only applies when running on Posit Connect. Ignoring it.",
            stacklevel=stacklevel,
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
        # Close a client created here; leave a caller's client open.
        with (
            ConnectClient.from_env() if client is None else nullcontext(client)
        ) as connect:
            existing = collaborator_principals(connect, guid)
            # Connect refuses some users outright, such as the content's
            # owner or an account that cannot publish, so one refusal must
            # not cost the users after it their grant.
            for username in pending:
                try:
                    principal = user_guid(connect, username)
                    if principal not in existing:
                        add_collaborator(connect, guid, principal)
                        existing.add(principal)
                except (ConnectError, LookupError, ValueError) as error:
                    warnings.warn(
                        f"Could not share trajectory access with {username!r}. {error}",
                        stacklevel=stacklevel,
                    )
                    continue
                _GRANTED.add((guid, username))
    except (ConnectError, LookupError, ValueError) as error:
        warnings.warn(
            f"Could not share trajectory access. {error}",
            stacklevel=stacklevel,
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
