"""Commons chat UI for private Posit Connect content."""

import os

import shiny
import shinychat
from chatlas import ChatAuto
from shiny import ui as shiny_ui
from shinychat.types import HistoryOptions

from commons import Commons, mcp_server, semantic_layer, ui

MCP_URL = os.environ["COMMONS_MCP_URL"].rstrip("/") + "/"
DATA_URL = MCP_URL.rstrip("/").removesuffix("/mcp") + "/"

page = shinychat.page_chat(
    "commons",
    id="chat",
    theme=ui.theme(),
    toolbar_global=shiny_ui.toolbar(
        shiny_ui.tags.a("Data service", href=DATA_URL, target="_blank", rel="noopener"),
        shiny_ui.input_dark_mode(),
    ),
)


def server(
    input: shiny.Inputs, output: shiny.Outputs, session: shiny.Session
) -> shinychat.Chat:
    agent = Commons(
        ChatAuto(
            os.getenv(
                "COMMONS_CHAT_MODEL",
                "anthropic/claude-sonnet-5",
            ),
        ),
        semantic_layer=semantic_layer(
            mcp_servers=[
                mcp_server(
                    "sales",
                    MCP_URL,
                    auth={
                        "headers": {
                            "Authorization": "Key " + os.environ["CONNECT_API_KEY"]
                        }
                    },
                    tools=[
                        "revenue",
                        "hospital_summary",
                        "hospital_event_counts",
                        "describe_table",
                        "run_sql",
                    ],
                )
            ]
        ),
    )
    session.on_ended(agent.close)
    return ui.server(
        "chat", agent, history=HistoryOptions(restore_mode="url", title=None)
    )


app = shiny.App(page, server)
