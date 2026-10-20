# Visitor API keys: proposed integration

This example currently uses its configured `CONNECT_API_KEY`. The following SDK integration is not part of the shipped application and does not change that behavior.

To call MCP as the signed-in visitor, install `posit-sdk` and associate a Connect API visitor-key integration with the agent, preserving its Anthropic association. The visitor needs access to both content items. In the per-session Shiny `server()` function:

```python
from posit.connect import Client

session_token = session.http_conn.headers.get("Posit-Connect-User-Session-Token")
if not session_token:
    raise ValueError("A signed-in Connect visitor is required.")
visitor = Client().with_user_session_token(
    session_token,
    audience=CONNECT_VISITOR_INTEGRATION_GUID,
)
headers = {"Authorization": "Key " + visitor.cfg.api_key}
```

The bootstrap client reads `CONNECT_SERVER` and `CONNECT_API_KEY`. The session token is exchanged for a visitor API key; it is not itself an MCP key. `audience` selects the integration when content has multiple associations. The SDK requires Connect 2025.01 or later.

Keep the returned credentials and MCP client scoped to the visitor. An exchange failure must not fall back to the publisher key. Validate visitor-key expiry, client reconnection, missing tokens, denied service access, and overlapping sessions before enabling this path.

Source: [posit-sdk client implementation and Shiny example](https://github.com/posit-dev/posit-sdk-py/blob/main/src/posit/connect/client.py).
