# commons

`commons` is a constructor for trustworthy data agents. It gives an LLM data, semantic, and context layers to work with, tools for querying them, and A/B/C provenance tags so every answer carries a classification as to its trustworthiness.

**Status: pre-alpha.** The agent and all three layers are implemented; the chat UI is not, so answers come back as text and server-rendered HTML rather than through a Shiny front end. Python 3.11 or later is required.

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

Behavior that both implementations must agree on belongs in [`tests/shared/`](https://github.com/posit-dev/commons/tree/main/tests/shared) at the repository root, which that directory's README defines as the authority. The provenance tag rules and display copy, the citation dialect, and the context layer's frontmatter handling are governed that way; both suites run those cases.
