"""Optional FastMCP/FastAPI service for server-owned DuckDB calculations."""

from __future__ import annotations

import asyncio
import json
import secrets
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from fastmcp import FastMCP
from fastmcp.server.dependencies import get_context, get_http_request
from fastmcp.tools import Tool, ToolResult
from pydantic import Field
from starlette.types import ASGIApp, Receive, Scope, Send

from ._registry import Registry

__all__ = ["Grant", "Registry", "create_app"]


@dataclass(frozen=True)
class Grant:
    """Execution tools and datasets available to one authenticated principal."""

    tools: frozenset[str]
    sources: frozenset[str]

    def __post_init__(self) -> None:
        object.__setattr__(self, "tools", frozenset(self.tools))
        object.__setattr__(self, "sources", frozenset(self.sources))


class _AccessPolicy:
    def __init__(
        self,
        app: ASGIApp,
        keys: dict[str, Grant] | None,
        proxy_grant: Grant,
    ) -> None:
        self.app = app
        self.keys = keys
        self.proxy_grant = proxy_grant

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or scope["path"] == "/":
            await self.app(scope, receive, send)
            return
        allowed: Grant | None = self.proxy_grant
        if self.keys is not None:
            headers = dict(scope["headers"])
            supplied = headers.get(b"x-api-key", b"")
            allowed = next(
                (
                    grant
                    for key, grant in self.keys.items()
                    if secrets.compare_digest(key.encode(), supplied)
                ),
                None,
            )
        if allowed is None:
            await JSONResponse({"detail": "Unauthorized"}, status_code=401)(
                scope, receive, send
            )
            return
        state = scope.setdefault("state", {})
        state["allowed_tools"] = allowed.tools
        state["allowed_sources"] = allowed.sources

        async def private_send(message: Any) -> None:
            if message["type"] == "http.response.start":
                message.setdefault("headers", []).append(
                    (b"cache-control", b"private, no-store")
                )
            await send(message)

        await self.app(scope, receive, private_send)


class _RegistryTool(Tool):
    registry: Any = Field(exclude=True)

    async def run(self, arguments: dict[str, Any]) -> ToolResult:
        request = get_http_request()
        context = get_context().request_context
        meta = context.meta if context is not None else None
        revision = getattr(meta, "commons_catalog_revision", None)
        envelope = await asyncio.to_thread(
            self.registry.execute,
            self.name,
            arguments,
            request.state.allowed_tools,
            revision,
            sources=request.state.allowed_sources,
        )
        return ToolResult(structured_content=envelope)


def create_app(
    registry: Registry,
    *,
    api_keys: dict[str, Grant] | None = None,
    trust_proxy: bool = False,
) -> FastAPI:
    """Require keys, or explicitly trust authentication by the hosting proxy.

    Only use ``trust_proxy=True`` when the application port is inaccessible
    except through an authenticating proxy such as private Connect content.
    """
    _validate_policy(registry, api_keys, trust_proxy)
    mcp = FastMCP("commons")
    _register_tools(mcp, registry)
    _register_resources(mcp, registry)
    transport = mcp.http_app(path="/", stateless_http=True, json_response=True)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> Any:
        async with transport.lifespan(app):
            yield

    app = FastAPI(
        title="commons semantic service",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.state.registry = registry
    app.add_middleware(
        _AccessPolicy,
        keys=dict(api_keys) if api_keys is not None else None,
        proxy_grant=Grant(frozenset(registry.operations), frozenset(registry.sources)),
    )
    _metadata_routes(app, registry)
    app.mount("/mcp", transport)
    return app


def _validate_policy(
    registry: Registry, api_keys: dict[str, Grant] | None, trust_proxy: bool
) -> None:
    if trust_proxy is True:
        if api_keys is not None:
            raise ValueError("Choose API keys or proxy trust, not both.")
        return
    if trust_proxy is not False:
        raise TypeError("trust_proxy must be an explicit boolean.")
    if not api_keys:
        raise ValueError(
            "Configure nonempty API credentials or explicitly trust the proxy."
        )
    for key, grant in api_keys.items():
        _validate_grant(registry, key, grant)


def _validate_grant(registry: Registry, key: str, grant: Grant) -> None:
    if not isinstance(key, str) or not key.strip():
        raise ValueError("Configure nonempty API credentials.")
    if not isinstance(grant, Grant):
        raise TypeError("API key policies must specify Grant(tools, sources).")
    if (
        not grant.tools <= registry.operations.keys()
        or not grant.sources <= registry.sources.keys()
    ):
        raise ValueError("An authorization policy names unknown tools or sources.")


def _request_catalog(registry: Registry) -> dict[str, Any]:
    state = get_http_request().state
    return registry.catalog(state.allowed_tools, state.allowed_sources)


def _register_tools(mcp: FastMCP, registry: Registry) -> None:
    def allowed(context: Any) -> bool:
        return any(
            record["name"] == context.component.name
            for record in _request_catalog(registry)["tools"]
        )

    for record in registry.operations.values():
        mcp.add_tool(
            _RegistryTool(
                name=record["name"],
                description=record["description"],
                parameters=record["inputSchema"],
                output_schema=record["outputSchema"],
                registry=registry,
                auth=allowed,
            )
        )


def _register_resources(mcp: FastMCP, registry: Registry) -> None:
    @mcp.resource("commons://catalog", mime_type="application/json")
    def catalog() -> str:
        return json.dumps(_request_catalog(registry))

    def allowed(context: Any) -> bool:
        state = get_http_request().state
        return str(context.component.uri) in registry.visible_resources(
            state.allowed_tools, state.allowed_sources
        )

    def read_resource(uri: str) -> Any:
        def read() -> str:
            return registry.resources[uri].text

        return read

    for resource in registry.resources.values():
        mcp.resource(
            resource.uri,
            name=resource.title,
            mime_type="text/plain",
            meta={"catalog_revision": registry.revision},
            auth=allowed,
        )(read_resource(resource.uri))


def _metadata_routes(app: FastAPI, registry: Registry) -> None:
    @app.get("/v1/catalog")
    def catalog(request: Request) -> dict[str, Any]:
        return registry.catalog(
            request.state.allowed_tools, request.state.allowed_sources
        )

    @app.get("/v1/measures")
    def measures(request: Request) -> dict[str, Any]:
        view = registry.catalog(
            request.state.allowed_tools, request.state.allowed_sources
        )
        return {
            "catalog_revision": registry.revision,
            "measures": [
                t for t in view["tools"] if t["execution_kind"] == "trusted_calculation"
            ],
        }

    @app.get("/v1/sources")
    def sources(request: Request) -> dict[str, Any]:
        return {
            "catalog_revision": registry.revision,
            "sources": registry.catalog(
                request.state.allowed_tools, request.state.allowed_sources
            )["sources"],
        }

    @app.get("/v1/contexts")
    def contexts(request: Request) -> dict[str, Any]:
        return {
            "catalog_revision": registry.revision,
            "contexts": [
                vars(r) | {"revision": registry.revision, "sources": sorted(r.sources)}
                for r in registry.visible_resources(
                    request.state.allowed_tools, request.state.allowed_sources
                ).values()
                if r.kind == "prose"
            ],
        }

    @app.get("/v1/contexts/{context_id}")
    def context(context_id: str, request: Request) -> PlainTextResponse:
        return _resource_response(registry, f"commons://contexts/{context_id}", request)

    @app.get("/v1/data-dictionaries/{source}")
    def dictionary(source: str, request: Request) -> PlainTextResponse:
        return _resource_response(
            registry, f"commons://sources/{source}/data-dict.yaml", request
        )


def _resource_response(
    registry: Registry, uri: str, request: Request
) -> PlainTextResponse:
    resource = registry.visible_resources(
        request.state.allowed_tools, request.state.allowed_sources
    ).get(uri)
    if resource is None:
        return PlainTextResponse("Unknown resource", status_code=404)
    return PlainTextResponse(
        resource.text, headers={"X-Commons-Catalog-Revision": registry.revision}
    )
