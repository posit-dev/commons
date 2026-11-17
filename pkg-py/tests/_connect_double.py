"""A Posit Connect server double for tests that grant or look up users.

It also serves the content item ``content-guid``, with Content Observability
off, and accepts a change to it.
"""

from __future__ import annotations

import json
from typing import Any

import httpx

from commons._connect import ConnectClient

DIRECTORY = {"ada": "guid-ada", "grace": "guid-grace"}


def connect_double(
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
