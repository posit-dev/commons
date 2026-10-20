# Agent UI on Posit Connect

Deploy this Shiny application beside the FastAPI/MCP service. Each visitor session gets its own Commons agent and remote clients. The Data service link opens the companion service. Conversation history uses Connect's persistent storage and the authenticated user's namespace.

Configure these content environment variables:

- `COMMONS_MCP_URL`: the full service URL, such as `https://connect.example.com/content/SERVICE-GUID/mcp/`.
- `CONNECT_SERVER`: the Connect server URL.
- `CONNECT_API_KEY`: a server-side key authorized to call the service. Never include it in the bundle.
- `ANTHROPIC_API_KEY`: supplied by an environment-variable integration attached to this content.
- `COMMONS_CHAT_MODEL`: optional; defaults to `anthropic/claude-sonnet-5`.

The agent enables approved revenue, hospital summaries and grouped event counts, table inspection, and custom SQL. Hospital SQL uses `source="hospital"`; sales SQL uses `source="warehouse"`. Dictionaries and context arrive through MCP resources.

Bundle `app.py`, a wheel built from this checkout with its locked `shiny` and `mcp` dependencies, and the `anthropic` SDK. Deploy using a saved Connect account:

```bash
uvx --from rsconnect-python rsconnect deploy shiny BUNDLE_DIRECTORY \
  -n YOUR_CONNECT_ACCOUNT -t "Commons agent" \
  -E CONNECT_API_KEY \
  -E CONNECT_SERVER=https://connect.example.com/ \
  -E COMMONS_MCP_URL=https://connect.example.com/content/SERVICE-GUID/mcp/
```

Attach the Anthropic integration before opening a session. Restrict both content items to the same authorized audience: the agent currently calls the service under its configured `CONNECT_API_KEY`.

Per-visitor authentication is not implemented in this application. [Visitor API key notes](visitor-keys.md) describe the supported SDK exchange and the lifecycle work required before enabling it.
