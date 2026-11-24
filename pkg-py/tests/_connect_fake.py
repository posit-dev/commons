"""Fake Posit Connect servers for tests.

``connect_fake()`` serves the user search and permissions that grants use, and
the content item ``content-guid``, with Content Observability off, and accepts
a change to it. ``connect_fixture_server()`` serves a content item's trace
lines, its jobs, and the content search, as the shared fixtures describe them,
and ``serve_connect()`` routes every client commons creates to it.
"""

from __future__ import annotations

import json
import re
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest

from commons._connect import ConnectClient
from tests._trajectories import fixture_line

DIRECTORY = {"ada": "guid-ada", "grace": "guid-grace"}


def connect_fake(
    *,
    users: dict[str, str] | None = None,
    permitted: Any = None,
    refused: list[str] | None = None,
    fail: str | None = None,
    seen: list[httpx.Request] | None = None,
) -> tuple[ConnectClient, list[httpx.Request]]:
    """A Connect server with the given users and existing permissions.

    A grant for a principal in `refused` gets the 400 Connect gives the
    content's owner.
    """
    users = DIRECTORY if users is None else users
    permitted = [] if permitted is None else permitted
    refused = [] if refused is None else refused
    seen = [] if seen is None else seen
    page_size = 500

    def route(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        path = request.url.path
        if fail is not None and fail in path:
            return httpx.Response(500, json={"error": "boom"})
        if path.endswith("/server_settings"):
            return httpx.Response(200, json={})
        if path.endswith("/permissions") and request.method == "GET":
            return httpx.Response(200, json=permitted)
        if path.endswith("/permissions"):
            if json.loads(request.read())["principal_guid"] in refused:
                return httpx.Response(400, json={"code": 74})
            return httpx.Response(200, json={})
        if path.endswith("/content/content-guid"):
            if request.method == "PATCH":
                return httpx.Response(200, json={})
            return httpx.Response(200, json={"otel_enabled": False})
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


def _window_nanos(value: str | None) -> int | None:
    if value is None:
        return None
    at = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    return int(at.timestamp()) * 1_000_000_000


def connect_fixture_server(
    server: dict[str, Any],
    *,
    content: Any = ...,
    settings: Any = ...,
    search: list[dict[str, Any]] | None = None,
) -> tuple[Callable[[httpx.Request], httpx.Response], list[httpx.Request]]:
    """A Connect server as connect.json's `traces.double` describes it.

    `content` and `settings` answer the content item and the server settings:
    absent is an empty object, and None fails with 500. `search` lists the
    content search's answers by page number.
    """
    content = {} if content is ... else content
    settings = {} if settings is ... else settings
    seen: list[httpx.Request] = []

    def serve_lines(lines: Any, params: httpx.QueryParams) -> httpx.Response:
        if isinstance(lines, dict):
            return httpx.Response(lines["status"])
        low = _window_nanos(params.get("from") or params.get("since"))
        high = _window_nanos(params.get("to"))

        def in_window(line: Any) -> bool:
            if isinstance(line, str):
                return True
            start = int(line[0].get("start", "1"))
            return (low is None or start >= low) and (high is None or start < high)

        keep = [line for line in lines if in_window(line)]
        page = keep[int(params.get("offset", "0")) :]
        if "page_size" in server:
            page = page[: server["page_size"]]
        total = server.get("total", len(keep))
        headers = {} if total is None else {"X-Total-Count": str(total)}
        if "version" in server:
            headers["Server"] = f"Posit Connect v{server['version']}"
        body = "".join(
            (line if isinstance(line, str) else fixture_line(line)) + "\n"
            for line in page
        )
        return httpx.Response(200, headers=headers, text=body)

    def answer(body: Any) -> httpx.Response:
        return httpx.Response(500) if body is None else httpx.Response(200, json=body)

    def route(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        path = request.url.path
        params = request.url.params
        if path == "/__api__/server_settings":
            return answer(settings)
        if path.endswith("/search/content"):
            assert search is not None
            return httpx.Response(200, json=search[int(params["page_number"]) - 1])
        rel = re.sub(r"^.*/__api__/v1/content/[^/]+/?", "", path)
        if rel == "":
            return answer(content)
        if rel == "traces":
            return serve_lines(server["traces"], params)
        jobs = server.get("jobs", [])
        if rel == "jobs":
            if isinstance(jobs, dict) and "body" in jobs:
                return httpx.Response(
                    200,
                    headers={"Content-Type": "application/json"},
                    text=jobs["body"],
                )
            if isinstance(jobs, dict):
                return httpx.Response(jobs["status"])
            return httpx.Response(200, json=[{"key": job["key"]} for job in jobs])
        match = re.fullmatch(r"jobs/([^/]+)/traces", rel)
        key = None if match is None else match.group(1)
        for job in jobs:
            if job["key"] == key:
                return serve_lines(job["traces"], params)
        raise AssertionError(f"unexpected request to {path}")

    return route, seen


def serve_connect(
    monkeypatch: pytest.MonkeyPatch, route: Callable[[httpx.Request], httpx.Response]
) -> list[httpx.Client]:
    """Send the requests of every HTTP client made in this test to `route`."""
    clients: list[httpx.Client] = []
    client_class = httpx.Client

    def make(*args: Any, **kwargs: Any) -> httpx.Client:
        client = client_class(*args, transport=httpx.MockTransport(route), **kwargs)
        clients.append(client)
        return client

    monkeypatch.setattr(httpx, "Client", make)
    return clients
