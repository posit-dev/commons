---
name: commons
description: >-
  Build and maintain self-service data agents created with Posit's commons Python package. Use when the user mentions a commons data agent or a project uses commons package APIs such as commons.Commons(), data_source(), semantic_layer(), measure(), context_layer(), or trajectory_read(), including onboarding, commons data dictionaries, trusted-artifact extraction, evaluation, and trajectory-based improvement. Do not use for unrelated data dictionaries, generic AI agents, or common or shared resources.
---

# commons

Read the relevant reference below before starting the corresponding task.

- [Onboarding](references/onboarding.md) - onboard and create a commons agent from existing materials.
- [Use data dictionaries with commons](references/data-dictionaries.md) - read alongside onboarding or extraction when creating, reviewing, or editing a data dictionary.
- [Extract commons context from existing data artifacts](references/extracting-from-artifacts.md) - turn a trusted Shiny app, Quarto report, Jupyter notebook, Python script, or SQL file into measures, governed definitions, dictionary edits, and free-text context, each carrying provenance back to its source.
- [Evaluating a commons agent](references/evaluation.md) - create an evaluation for a commons agent to determine whether it is working correctly.
- [Iterate on a commons agent from trajectories](references/iterating-from-trajectories.md) - analyze logged conversations and review feedback, then propose semantic layer or context layer changes.

## Working principles

- Aim for a solid data foundation, but not perfection. The data should be trustworthy and have a reasonably solid creation process, but it can continue to improve after the agent is built.
- Give the agent data that is fine-grained enough for custom manipulation, but trusted and cleaned enough that it will not make unforced errors or need context that reasonably belongs in the data preparation process.
- Keep context DRY. Information in a data dictionary, for example, should not also appear in free text in the context layer.
- Verify anything that can be verified.
- Preserve provenance. Everything that can be cited should be cited.
- Never fabricate information or pull from general knowledge without the user's permission. Include only scope-relevant information from approved sources.
- Look for uncertainties and contradictions rather than waiting for them, and surface them instead of resolving them silently. Prefer fixing a conflict in the upstream data over working around it in commons.

## Agent project layout

A commons agent project follows this on-disk convention. The onboarding, extraction, and trajectory references build on it.

```
my-agent/
├── app.py                   # Shiny entry point
├── agent.py                 # reusable commons.Commons() construction
├── deploy.py                # prewarm the agent and deploy the app
├── requirements.txt         # what the deployed app installs
├── AGENTS.md                # or the active coding agent's equivalent
├── instructions.md          # optional concise, always-needed guidance
├── dictionaries/
│   └── warehouse.yaml       # one data-dict.yaml per data_source(), named
│                            # to match the source's key in data_sources
├── measures/
│   ├── sales_dashboard.py   # measures grouped by source artifact (default
│   └── churn_report.py      # landing spot only; reorganizing later is safe)
└── context/
    ├── sales-dashboard.md   # free-text context, one file per artifact
    └── churn-report.md
```

Measure files are Python modules, so name them with underscores. `semantic_layer("measures")` loads every `.py` file in the directory except `__init__.py`, and puts the directory on `sys.path` while each file loads, so measure files can import shared helpers from one another by plain absolute import. A helper module's name must not collide with the standard library or an installed package.

## Provenance

Every contribution points back to the source it came from with a machine-parseable string. When the host offers a commit-pinned permalink to a line range, use it directly — it is clickable and pins the same repo, sha, path, and lines in one token:

```
https://github.com/org/sales-dashboard/blob/abc1234/app.py#L120-L145
```

For hosts without a permalink convention (a bare git remote, an internal server), fall back to the host-agnostic grammar:

```
<repo-url>@<sha> <path>#L<start>-L<end>
```

For artifacts not under version control, prefer a stable URL that identifies the source (e.g. a published report or deployed app) over a local path; either way, use `<location> (retrieved <yyyy-mm-dd>)`, where `<location>` is that URL or, failing that, a local path. Measures born from the iterate skill rather than an artifact self-reference their origin: `trajectory analysis (<yyyy-mm-dd>)`.

Where each kind of contribution carries it:

- Measures: one or more strings in `@commons.measure(provenance=[...])`. Provenance never reaches the model; the model sees the measure's name, title, description (the docstring or `description=`), and the descriptions of its model-supplied parameters. A provenance URL becomes a "View source" link under the measure's result in the chat.
- Context files: the same string under a `provenance` key in YAML frontmatter:
  ```yaml
  ---
  provenance: https://github.com/org/sales-dashboard/blob/abc1234/app.py#L120-L145
  ---
  ```
  `context_layer()` strips frontmatter before indexing, so it never reaches the model.
- Dictionary edits: git commit messages; optionally a column's `details` when a caveat comes straight from artifact code.

Example extracted measure:

```python
from typing import Annotated

from pydantic import Field
from sqlalchemy import Engine, text

import commons


@commons.measure(
    provenance=[
        "https://github.com/org/sales-dashboard/blob/abc1234/app.py#L120-L145",
    ],
)
def quarterly_revenue(
    quarter: Annotated[str, Field(description='Fiscal quarter, e.g. "2026 Q2".')],
    warehouse: commons.Injected[Engine],
) -> float:
    """Revenue for a fiscal quarter as reported in the sales dashboard's
    "Revenue (QTD)" value box. Excludes tax and intra-company transfers."""
    ...
```

A parameter annotated `Annotated[T, Field(description=...)]` is supplied by the model. A parameter annotated `commons.Injected[T]` is supplied by commons and never seen by the model. When `data_sources` is a mapping, an injected parameter named after one of its keys receives that source's connection: the SQLAlchemy `Engine` for a database, or the DuckDB connection for data frames and pins. Any other injected parameter keeps its default, so give objects a measure needs, such as a pins board or an API client, a default. Every parameter must be one or the other.
