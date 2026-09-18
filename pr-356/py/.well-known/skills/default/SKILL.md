---
name: commons
description: >
  AI Agents for Data Analysis. Use when writing Python code that uses the commons package.
license: MIT
compatibility: Requires Python >=3.11.
---

# commons

AI Agents for Data Analysis

## Installation

```bash
pip install commons
```

## API overview

### Main functions

The main agent constructor, plus the building blocks for a commons agent.

- `Commons`: A trustworthy agent that answers questions about its data
- `data_source`: Create a data source from an engine, a pins board, or named frames
- `semantic_layer`: Collect measures into a semantic layer
- `measure`: Mark a function as a measure
- `context_layer`: Create a context layer from text or Markdown files

### Commons Methods

Methods for the Commons class

- `Commons.__repr__`
- `Commons.__deepcopy__`
- `Commons.chat`
- `Commons.stream_async`
- `Commons.chat_async`
- `Commons.stream`
- `Commons.chat_structured`
- `Commons.chat_structured_async`
- `Commons.extract_data`
- `Commons.extract_data_async`
- `Commons.to_solver`
- `Commons.citation_corpus`
- `Commons.prewarm`
- `Commons.add_turn`
- `Commons.set_turns`
- `Commons.queue_restore_reminder`

### Supporting types

The objects the constructors return, and the values they carry.

- `DataSource`: Tables an agent can query, and the dictionary that describes them
- `SemanticLayer`: The trusted calculations an agent can run
- `ContextLayer`: Text that helps an agent interpret its data source
- `Measure`: A trusted calculation the agent can run
- `Injected`: Runtime representation of an annotated type
- `Tag`: How an answer was produced
- `list_tables`: The table names an agent can query on `source`

### DataSource Methods

Methods for the DataSource class

- `DataSource.from_frames`
- `DataSource.from_engine`
- `DataSource.from_board`
- `DataSource.query`
- `DataSource.ensure_loaded`
- `DataSource.dialect`

### Shiny UI and server

Put a commons agent inside of an interactive chat app. Needs the `shiny` extra.

- `ui.app`
- `ui.server`
- `ui.theme`
- `ui.commons_chat_dependency`
- `ui.asset_base_url`

## Resources

- [Full documentation](https://posit-dev.github.io/commons/py/)
- [llms.txt](llms.txt) — Indexed API reference for LLMs
- [llms-full.txt](llms-full.txt) — Comprehensive documentation for LLMs
