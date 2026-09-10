# commons

`commons` is a constructor for trustworthy data agents. It gives an LLM data, semantic, and context layers to work with, tools for querying them, and A/B/C provenance tags so every answer carries a classification as to its trustworthiness.

**Status: alpha.** The agent, the three layers (data, semantics, and context), and the chat UI are implemented: `commons.ui.server()` wires an agent to a chat element in a py-shiny app, and outside one, answers come back as text and server-rendered HTML. Python 3.11 or later is required.

## Optional extras

The core dependencies will allow you to build and query an agent. Installing the `shiny` group (via `pip install commons[shiny]`) will additionally install everything `commons.ui` needs to serve a full chat UI; importing `commons.ui` without it raises an `ImportError` that names the missing packages and the install command. Nothing in commons currently needs the `tracing` group (it is a placeholder for future functionality).

## Get started

An agent needs a chat client and at least one data source. A semantic layer of trusted calculations and a context layer of prose are both optional. The semantic layer changes which tools the agent registers, since a measure is what `call_measure` calls. The context layer does not: `search_context` is always registered, and without a layer behind it the tool reports that none is configured. Every parameter the model supplies to a measure needs a description, which is what the model reads to decide how to call it.

```python
from typing import Annotated

import chatlas
import commons
import pandas as pd
from pydantic import Field

sales = pd.DataFrame(
    {"revenue": [500.0, 900.0, 300.0], "region": ["EMEA", "Americas", "EMEA"]}
)


@commons.measure(description="Total revenue for one region.")
def region_revenue(
    region: Annotated[str, Field(description="Which region to total.")] = "EMEA",
) -> float:
    return float(sales[sales["region"] == region]["revenue"].sum())


agent = commons.Commons(
    chatlas.ChatAnthropic(model="claude-sonnet-5"),
    commons.data_source(sales=sales, dictionary="data-dict.yaml"),
    semantic_layer=commons.semantic_layer(region_revenue),
    context_layer=commons.context_layer(files=["reporting-policy.md"]),
)

agent.chat("What is EMEA revenue?")
```

`region_revenue` is trusted code, so an answer that runs it is tagged `Tag.A` and displays the verified marker. A question no measure covers sends the agent to `run_sql` or the context layer instead, and the answer comes back cited or untrusted depending on whether it quotes something the context layer can verify.

Use `stream_async()` in place of `chat()` to stream an answer as it arrives. Its signature is chatlas's, so a chat UI can drive the agent directly.

`commons.ui` puts the agent behind a py-shiny chat, which needs the `shiny` extra: `pip install "commons[shiny]"`. `commons.ui.app(agent)` is a complete app for local development, and it shares its one agent across every session. A deployed app builds the page with `commons.ui.theme()`, calls `commons.ui.server("chat", agent)` in its server function, and constructs the agent there so each session gets its own.

An agent is a chatlas `Chat`, so `get_tools()`, `system_prompt`, `set_model_params()` and the rest of that surface work on it directly. `chat()` and `stream_async()` are the only ways to ask it something. The other entry points chatlas offers would answer without the citation scanner and the provenance tag, so each of them raises `NotImplementedError`.

`demo.py` here is a fuller worked example, an agent over made-up forest canopy data with two measures and a context layer. Run it with `shiny run demo.py` for the chat, or `python demo.py` to ask the same questions from the terminal. `demo.ipynb` is the same agent in a notebook, with cells for reading what it registered and adding a measure of your own. `pkg-r/inst/demo.R` is the R package's version of it.

Behavior that both implementations must agree on belongs in [`tests/shared/`](https://github.com/posit-dev/commons/tree/main/tests/shared) at the repository root, which that directory's README defines as the authority. The provenance tag rules and display copy, the citation dialect, and the context layer's frontmatter handling are governed that way; both suites run those cases.
