"""A Posit Connect API client, covering what commons needs from Connect.

Connect gives running content an ephemeral owner-scoped ``CONNECT_API_KEY``
(``Applications.DefaultAPIKeyEnv``, on by default), so content can act on its
own behalf without a publisher configuring anything.
``pkg-r/R/connect.R`` is its counterpart.
"""

from __future__ import annotations

import os
from typing import Any, Self

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
    """A Posit Connect API request failed, either in transit or with a status.

    ``status_code`` is ``None`` when the request never got a response.
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
