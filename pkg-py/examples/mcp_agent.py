"""Chat with the local commons MCP demo, optionally in the Shiny UI."""

import argparse
import os

from chatlas import ChatAuto

from commons import Commons, mcp_server, semantic_layer


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--model", required=True, help="A chatlas provider/model string."
    )
    parser.add_argument("--url", default="http://127.0.0.1:8000/mcp/")
    parser.add_argument("--ui", action="store_true", help="Open the Shiny chat UI.")
    parser.add_argument("question", nargs="?", default="What is total revenue?")
    args = parser.parse_args()
    headers = {}
    if service_key := os.getenv("COMMONS_DEMO_API_KEY"):
        headers["X-API-Key"] = service_key
    if authorization := os.getenv("COMMONS_MCP_AUTHORIZATION"):
        headers["Authorization"] = authorization
    if not headers:
        parser.error("Set COMMONS_DEMO_API_KEY or COMMONS_MCP_AUTHORIZATION.")
    agent = Commons(
        ChatAuto(args.model),
        semantic_layer=semantic_layer(
            mcp_servers=[
                mcp_server(
                    "sales",
                    args.url,
                    auth={"headers": headers},
                )
            ]
        ),
    )
    try:
        if args.ui:
            from commons import ui

            ui.app(agent).run(port=8001)
        else:
            agent.chat(args.question)
    finally:
        agent.close()


if __name__ == "__main__":
    main()
