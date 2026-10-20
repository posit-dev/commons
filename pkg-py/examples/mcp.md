# Remote commons example

A Python commons agent can use a FastMCP/FastAPI service over MCP without a local data source or code worker. The service owns DuckDB connections; the agent imports authorized dictionaries, context, and measure definitions as MCP resources.

From `pkg-py/`, install the optional dependencies:

```bash
uv sync --all-extras
```

Follow [the service example](connect-mcp/README.md) to run it with an explicit private key. It exposes three tools with the minimal four-order dataset: `revenue`, `describe_table`, and `run_sql`. Adding hospital data enables `hospital_summary` and `hospital_event_counts`, for five tools total. The bundled public snapshots are entirely synthetic.

Configure a chatlas provider and use the same service key in the agent:

```bash
COMMONS_DEMO_API_KEY="$YOUR_LOCAL_SERVICE_KEY" \
  uv run python examples/mcp_agent.py --model PROVIDER/MODEL "What is total revenue?"
```

Add `--ui` to serve the local chat UI on port 8001. That local command shares one agent, so use one visitor at a time. The [Connect agent example](connect-agent/README.md) creates an independent agent per visitor session and receives its Anthropic key from a Connect integration.

Approved calculations carry provenance tag A and produce Trusted answers. Custom SQL carries B and produces Cited with a verified quote, or Untrusted without one. Metadata carries no calculation tag.

API key policies grant both tools and named sources. Catalogs, resource listings, direct resource reads, and execution honor those grants. `describe_table` explicitly permits up to five sample rows in addition to schema. Proxy authentication requires the named `trust_proxy=True` opt-in and a port reachable only through the authenticating proxy. The service disables documentation endpoints and shared response caching.

Queries have a two-second database deadline, 100-row output cap, and 64,000-byte data cap. Input has byte, token, and nesting limits. The deadline excludes connection startup and final formatting. The driver can materialize one oversized cell before rejecting it; use a streaming driver for large binary data.

For private Connect content, keep the full content prefix in the MCP URL and configure the agent's `Authorization: Key ...` header server-side. Never put that key in the bundle, a model argument, or public documentation. The current examples use configured service credentials; OAuth, visitor-key renewal, arbitrary remote code, and tenant-specific connection factories are not implemented.

Run real HTTP integration tests without a model API key:

```bash
uv run pytest tests/test_mcp.py tests/test_hospital_mcp.py -q
```
