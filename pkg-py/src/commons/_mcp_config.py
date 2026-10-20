"""MCP connection configuration without network or optional dependency imports."""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Any
from urllib.parse import SplitResult, urlsplit


@dataclass(frozen=True)
class MCPServer:
    """Immutable connection configuration with credentials excluded from repr."""

    name: str
    url: str
    headers: Mapping[str, str] = field(repr=False)
    tools: Sequence[str]

    def __post_init__(self) -> None:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", self.name):
            raise ValueError("MCP server names must be provider-safe identifiers.")
        _validate_url(self.url)
        object.__setattr__(self, "headers", _credential_headers(self.headers))
        object.__setattr__(self, "tools", _selected_tools(self.name, self.tools))


def mcp_server(
    name: str,
    url: str,
    *,
    auth: Mapping[str, Any],
    tools: Sequence[str],
) -> MCPServer:
    """Configure a commons-compatible server without connecting.

    Use ``auth={"headers": {"X-API-Key": key}}``. This configuration supports
    header authentication; HTTP is allowed only for loopback development.
    """
    if not isinstance(auth, Mapping) or set(auth) != {"headers"}:
        raise ValueError("MCP requires header authentication.")
    return MCPServer(name, url, auth["headers"], tools)


def _validate_url(url: str) -> None:
    parsed = _parse_url(url)
    if not parsed.hostname or parsed.scheme not in {"https", "http"}:
        raise ValueError("MCP requires an absolute HTTP(S) URL.")
    if parsed.scheme == "http" and parsed.hostname not in {
        "localhost",
        "127.0.0.1",
        "::1",
    }:
        raise ValueError("MCP requires HTTPS except on loopback hosts.")
    if (
        parsed.username is not None
        or parsed.password is not None
        or "?" in url
        or "#" in url
    ):
        raise ValueError("MCP URLs cannot contain credentials, queries, or fragments.")


def _parse_url(url: str) -> SplitResult:
    if (
        not isinstance(url, str)
        or not url
        or "\\" in url
        or any(ord(character) <= 32 or ord(character) == 127 for character in url)
    ):
        raise ValueError("MCP requires an absolute HTTP(S) URL.")
    try:
        parsed = urlsplit(url)
        _ = parsed.port  # Validate port syntax/range without changing the URL.
    except ValueError:
        raise ValueError("MCP requires an absolute HTTP(S) URL.") from None
    if parsed.netloc.endswith(":"):
        raise ValueError("MCP requires an absolute HTTP(S) URL.")
    return parsed


def _credential_headers(headers: Mapping[str, str]) -> Mapping[str, str]:
    if not isinstance(headers, Mapping) or not headers:
        raise ValueError("Authentication headers must be nonempty string pairs.")
    for key, value in headers.items():
        if not _valid_header_pair(key, value):
            raise ValueError("Authentication headers must be nonempty string pairs.")
    if len({key.casefold() for key in headers}) != len(headers):
        raise ValueError("Authentication headers must have unique names.")
    return MappingProxyType(dict(headers))


def _valid_header_pair(key: object, value: object) -> bool:
    if not isinstance(key, str) or not isinstance(value, str):
        return False
    return (
        bool(re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", key))
        and bool(value.strip())
        and "\r" not in value
        and "\n" not in value
    )


def _selected_tools(name: str, tools: Sequence[str]) -> tuple[str, ...]:
    if (
        isinstance(tools, str)
        or not isinstance(tools, Sequence)
        or not tools
        or any(not isinstance(tool, str) for tool in tools)
    ):
        raise ValueError("Select a nonempty list of unique MCP tools.")
    if len(set(tools)) != len(tools):
        raise ValueError("Select a nonempty list of unique MCP tools.")
    for tool in tools:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", tool) or len(f"{name}__{tool}") > 64:
            raise ValueError(
                "Remote tool aliases must be provider-safe and <=64 chars."
            )
    return tuple(tools)


def collect_servers(configs: Sequence[MCPServer]) -> tuple[MCPServer, ...]:
    servers = tuple(configs)
    if any(not isinstance(server, MCPServer) for server in servers):
        raise TypeError("mcp_servers must contain configurations from mcp_server().")
    if len({server.name for server in servers}) != len(servers):
        raise ValueError("MCP server names must be unique.")
    aliases = [f"{server.name}__{tool}" for server in servers for tool in server.tools]
    if len(aliases) != len(set(aliases)):
        raise ValueError("MCP tool aliases must be unique.")
    return servers
