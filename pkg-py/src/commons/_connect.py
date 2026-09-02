"""A Posit Connect API client, covering what commons needs from Connect.

Connect gives running content an ephemeral owner-scoped ``CONNECT_API_KEY``
(``Applications.DefaultAPIKeyEnv``, on by default), so content can act on its
own behalf without a publisher configuring anything.
``pkg-r/R/connect.R`` is its counterpart.
"""

from __future__ import annotations

import os
from typing import Any

import httpx

__all__ = [
    "ConnectClient",
    "ConnectError",
    "connect_content_guid",
    "is_connect_runtime",
]


def is_connect_runtime() -> bool:
    """Is this process running as content on Posit Connect?"""
    return os.environ.get("POSIT_PRODUCT") == "CONNECT" or bool(
        os.environ.get("CONNECT_CONTENT_GUID")
    )


def connect_content_guid() -> str:
    """This content's GUID, or an empty string when it has none."""
    return os.environ.get("CONNECT_CONTENT_GUID", "")


class ConnectError(RuntimeError):
    """A Posit Connect API request failed."""

    def __init__(self, method: str, url: httpx.URL, status_code: int) -> None:
        # Named by path rather than by response: the request carries the API
        # key in a header, and this message can reach a log or a bug report.
        super().__init__(
            f"Posit Connect returned {status_code} for {method} {url.path}"
        )
        self.status_code = status_code


class ConnectClient:
    """Authenticated access to one Posit Connect server's v1 API."""

    def __init__(
        self, server: str, api_key: str, *, http: httpx.Client | None = None
    ) -> None:
        self.server = normalize_server(server)
        self.api_key = api_key
        self._http = httpx.Client() if http is None else http

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
        """Perform a request against ``/__api__/v1/<path>``."""
        response = self._http.request(
            method,
            "/".join((self.server, "__api__", "v1", *path)),
            params=params,
            json=json,
            headers={"Authorization": f"Key {self.api_key}"},
        )
        if response.is_error:
            raise ConnectError(method, response.request.url, response.status_code)
        return response


def normalize_server(server: str) -> str:
    """Reduce the forms a publisher might paste to one base URL."""
    return server.rstrip("/").removesuffix("/__api__").rstrip("/")
