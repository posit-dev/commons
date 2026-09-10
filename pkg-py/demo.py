"""A self-contained commons agent over made-up forest canopy data.

    uv run --with anthropic shiny run demo.py   # the chat
    uv run --with anthropic python demo.py      # the same questions, in the terminal

The chat is assembled here rather than through `commons.ui.app()`, because
this is the shape a deployed app takes: one agent per session, built inside
the server function. `pkg-r/inst/demo.R` is the same app. The terminal path
is what `demo.ipynb` drives, through `ask()`.

The client comes from `chatlas.ChatAuto`, so `CHATLAS_CHAT_PROVIDER_MODEL`
picks a different provider without editing this file. chatlas ships no
provider SDK and neither does commons, hence the `--with`. For Claude on
Bedrock:

    export CHATLAS_CHAT_PROVIDER_MODEL=bedrock-anthropic/us.anthropic.claude-sonnet-5
    uv run --with 'anthropic[bedrock]' shiny run demo.py
"""

from __future__ import annotations

import asyncio
import os
from pathlib import Path
from tempfile import mkdtemp
from typing import Any

import chatlas
import pandas as pd
import shinychat
from shiny import App, Inputs, Outputs, Session

import commons

DEFAULT_MODEL = "anthropic/claude-sonnet-5"

stands = pd.DataFrame(
    {
        "stand_id": range(1, 9),
        "name": [
            "Nehalem Bench",
            "Saddle Mountain",
            "Mohawk Divide",
            "Fall Creek",
            "Winberry Ridge",
            "Sprague Rim",
            "Chiloquin Flat",
            "Antelope Draw",
        ],
        "county": [
            "Clatsop",
            "Clatsop",
            "Lane",
            "Lane",
            "Lane",
            "Klamath",
            "Klamath",
            "Klamath",
        ],
        "forest_type": [
            "Douglas-fir",
            "Sitka spruce",
            "Douglas-fir",
            "mixed conifer",
            "Douglas-fir",
            "ponderosa pine",
            "ponderosa pine",
            "lodgepole pine",
        ],
        "status": [
            "established",
            "established",
            "established",
            "established",
            "regeneration",
            "established",
            "established",
            "regeneration",
        ],
        "acres": [1240, 860, 3150, 720, 410, 2480, 1590, 640],
    }
)

surveys = pd.DataFrame(
    {
        "stand_id": [stand for stand in range(1, 9) for _ in (0, 1)],
        "survey_year": [2021, 2026] * 8,
        "canopy_pct": [
            78, 81,
            84, 86,
            71, 74,
            62, 67,
            18, 34,
            45, 47,
            52, 49,
            12, 26,
        ],
    }
)  # fmt: skip

NOTES = """\
Canopy cover is always acre-weighted. A plain average across stands treats a 400-acre unit the same as a 4,000-acre one.

Baseline canopy statistics cover established stands only; regeneration units are tracked separately until they close canopy.

The surveys table has one row per stand per survey year, so a query that doesn't pin a year mixes survey cycles.
"""


def notes_file() -> Path:
    path = Path(mkdtemp()) / "canopy-notes.md"
    path.write_text(NOTES)
    return path


# Written once, then read by every session's context layer.
NOTES_FILE = notes_file()


@commons.measure(
    description=(
        "Acre-weighted canopy cover for each county, from the most recent survey."
    )
)
def canopy_by_county(warehouse: commons.Injected[Any]) -> pd.DataFrame:
    return warehouse.execute(
        """
        SELECT county,
               SUM(canopy_pct * acres) / SUM(acres) AS canopy_pct,
               SUM(acres) AS acres
        FROM stands JOIN surveys USING (stand_id)
        WHERE status = 'established'
          AND survey_year = (SELECT MAX(survey_year) FROM surveys)
        GROUP BY county ORDER BY canopy_pct DESC
        """
    ).fetchdf()


@commons.measure(
    description="Established stands with the least canopy cover today, thinnest first."
)
def low_canopy_stands(warehouse: commons.Injected[Any]) -> pd.DataFrame:
    return warehouse.execute(
        """
        SELECT name, county, forest_type, canopy_pct, acres
        FROM stands JOIN surveys USING (stand_id)
        WHERE status = 'established'
          AND survey_year = (SELECT MAX(survey_year) FROM surveys)
        ORDER BY canopy_pct
        """
    ).fetchdf()


def client() -> chatlas.Chat:
    """A chat client, from `CHATLAS_CHAT_PROVIDER_MODEL` when it is set."""
    return chatlas.ChatAuto(os.getenv("CHATLAS_CHAT_PROVIDER_MODEL") or DEFAULT_MODEL)


def agent() -> commons.Commons:
    """The canopy agent, over all three layers."""
    return commons.Commons(
        client(),
        # Named, because a measure's `warehouse` argument is injected by name.
        {"warehouse": commons.data_source(stands=stands, surveys=surveys)},
        semantic_layer=commons.semantic_layer(canopy_by_county, low_canopy_stands),
        context_layer=commons.context_layer(files=[NOTES_FILE]),
    )


QUESTIONS = [
    # Covered by a measure, so the answer should come back verified.
    "Which county has the most canopy cover?",
    "Which stands have the least canopy cover?",
    # No measure covers a single stand's change over time, so this one has to
    # reach run_sql, and the answer is untrusted or cited instead.
    "How much canopy has Winberry Ridge gained since 2021?",
]


def tools_run(canopy: commons.Commons) -> list[str]:
    """Which tools the conversation has run, in order."""
    return [
        content.name
        for turn in canopy.get_turns()
        for content in turn.contents
        if isinstance(content, chatlas.ContentToolResult)
    ]


async def ask(canopy: commons.Commons, question: str) -> None:
    """Stream one answer, with a line naming each tool as it runs.

    `content="all"` is the mode a chat UI drives an agent through. Asking for
    text instead yields a bare "\\n\\n" per tool result, standing in for the
    content it is not emitting, which a terminal shows as a blank gap that
    grows with the number of tools.
    """
    print(f"\n{'=' * 72}\n>>> {question}\n{'=' * 72}", flush=True)
    async for chunk in await canopy.stream_async(question, content="all"):
        if isinstance(chunk, chatlas.ContentToolRequest):
            print(f"\n[{chunk.name}]", flush=True)
        elif isinstance(chunk, str):
            # The provenance marker and any citation arrive as their own
            # chunks of HTML; a UI renders them, so give them their own line.
            lead = "\n\n" if chunk.startswith("<shiny-aside") else ""
            print(f"{lead}{chunk}", end="", flush=True)
    print(flush=True)


async def main() -> None:
    canopy = agent()
    for question in QUESTIONS:
        await ask(canopy, question)


# Derived from QUESTIONS, so the chat suggests what the terminal run asks.
GREETING = (
    "Chat with this agent to learn about canopy cover in Oregon's forests."
    "\n\nHere are some example questions:\n\n"
) + "".join(
    f"- <span class='suggestion'>{question}</span>\n" for question in QUESTIONS
)

app_ui = shinychat.page_chat(
    "Canopy cover explorer",
    id="chat",
    greeting=GREETING,
    theme=commons.ui.theme(),
)


def app_server(input: Inputs, output: Outputs, session: Session) -> None:
    # One agent per session, so each visitor gets their own agent state.
    commons.ui.server("chat", agent())


app = App(app_ui, app_server)


if __name__ == "__main__":
    asyncio.run(main())
