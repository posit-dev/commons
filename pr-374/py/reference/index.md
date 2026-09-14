# API Reference


## Main functions


The main agent constructor, plus the building blocks for a commons agent.


[Commons](Commons.md#commons.Commons)  
A trustworthy agent that answers questions about its data.

[data_source()](data_source.md#commons.data_source)  
Create a data source from an engine, a pins board, or named frames.

[semantic_layer()](semantic_layer.md#commons.semantic_layer)  
Collect measures into a semantic layer.

[measure()](measure.md#commons.measure)  
Mark a function as a measure.

[context_layer()](context_layer.md#commons.context_layer)  
Create a context layer from text or Markdown files.


## Commons Methods


Methods for the Commons class


[Commons.__repr__()](Commons.__repr__.md#commons.Commons.__repr__)  

[Commons.__deepcopy__()](Commons.__deepcopy__.md#commons.Commons.__deepcopy__)  

[Commons.chat()](Commons.chat.md#commons.Commons.chat)  
Ask a question and wait for the whole answer.

[Commons.stream_async()](Commons.stream_async.md#commons.Commons.stream_async)  
Ask a question and stream the answer as it arrives.

[Commons.chat_async()](Commons.chat_async.md#commons.Commons.chat_async)  

[Commons.stream()](Commons.stream.md#commons.Commons.stream)  

[Commons.chat_structured()](Commons.chat_structured.md#commons.Commons.chat_structured)  

[Commons.chat_structured_async()](Commons.chat_structured_async.md#commons.Commons.chat_structured_async)  

[Commons.extract_data()](Commons.extract_data.md#commons.Commons.extract_data)  

[Commons.extract_data_async()](Commons.extract_data_async.md#commons.Commons.extract_data_async)  

[Commons.to_solver()](Commons.to_solver.md#commons.Commons.to_solver)  

[Commons.citation_corpus()](Commons.citation_corpus.md#commons.Commons.citation_corpus)  
The trusted text this agent's citations are verified against.

[Commons.prewarm()](Commons.prewarm.md#commons.Commons.prewarm)  
Build the caches the first question would otherwise pay for.

[Commons.add_turn()](Commons.add_turn.md#commons.Commons.add_turn)  
Add a turn, restarting the citation request if a person spoke.

[Commons.set_turns()](Commons.set_turns.md#commons.Commons.set_turns)  
Replace the conversation, dropping any reminder queued for it.

[Commons.queue_restore_reminder()](Commons.queue_restore_reminder.md#commons.Commons.queue_restore_reminder)  
Tell the next turn that the session behind its history is gone.


## Supporting types


The objects the constructors return, and the values they carry.


[DataSource](DataSource.md#commons.DataSource)  
Tables an agent can query, and the dictionary that describes them.

[SemanticLayer](SemanticLayer.md#commons.SemanticLayer)  
The trusted calculations an agent can run.

[ContextLayer](ContextLayer.md#commons.ContextLayer)  
Text that helps an agent interpret its data source.

[Measure](Measure.md#commons.Measure)  
A trusted calculation the agent can run.

[Injected](Injected.md#commons.Injected)  

[Tag](Tag.md#commons.Tag)  
How an answer was produced.

[list_tables()](list_tables.md#commons.list_tables)  
The table names an agent can query on `source`.


## DataSource Methods


Methods for the DataSource class


[DataSource.from_frames()](DataSource.from_frames.md#commons.DataSource.from_frames)  
Load named data frames into a locked-down in-process DuckDB.

[DataSource.from_engine()](DataSource.from_engine.md#commons.DataSource.from_engine)  
Query a caller's database directly. Nothing is copied.

[DataSource.from_board()](DataSource.from_board.md#commons.DataSource.from_board)  
Expose a pins board's pins as tables, each read on first use.

[DataSource.query()](DataSource.query.md#commons.DataSource.query)  
Run one read-only statement, rejecting anything else first.

[DataSource.ensure_loaded()](DataSource.ensure_loaded.md#commons.DataSource.ensure_loaded)  
Read every pin this source has not read yet.

[DataSource.dialect()](DataSource.dialect.md#commons.DataSource.dialect)  
A hint for the system prompt, not a contract.


## Shiny UI and server


Put a commons agent inside of an interactive chat app. Needs the `shiny` extra.


[ui.app()](ui.app.md#commons.ui.app)  
Build a complete app around a commons agent.

[ui.server()](ui.server.md#commons.ui.server)  
Wire a commons agent to the chat element `id` on the page.

[ui.theme()](ui.theme.md#commons.ui.theme)  
Build the theme a commons chat page uses.

[ui.commons_chat_dependency()](ui.commons_chat_dependency.md#commons.ui.commons_chat_dependency)  
The dependency serving the chat script, stylesheet and icons.

[ui.asset_base_url()](ui.asset_base_url.md#commons.ui.asset_base_url)  
The URL the assets are served under on a page.
