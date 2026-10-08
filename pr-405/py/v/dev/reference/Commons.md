## Commons


A trustworthy agent that answers questions about its data.


Usage

``` python
Commons(
    client,
    data_sources,
    semantic_layer=None,
    context_layer=None,
    *,
    instructions=None
)
```


Given a `chatlas.Chat` for the provider and model, the data sources it can query, and optionally a semantic layer of trusted calculations and a context layer of prose, a [Commons](Commons.md#commons.Commons) agent will allow for agent interactions with answers classified by how they were produced.

A [Commons](Commons.md#commons.Commons) agent inherits directly from `chatlas.Chat` and relies on the chatlas infrastructure to set up the LLM provider and model. [Commons](Commons.md#commons.Commons) initializes its own chat state and system prompt to ensure provenance and citation tracking. Passing a custom system prompt in the [Commons](Commons.md#commons.Commons) constructor is ignored with a warning; use `instructions` to add to commons' prompt instead. For best results, enable thinking where the provider and model support it.

[chat()](Commons.chat.md#commons.Commons.chat) and [stream_async()](Commons.stream_async.md#commons.Commons.stream_async) are the currently supported ways to interact with a [Commons](Commons.md#commons.Commons) agent. The other entry points chatlas offers ([chat_async()](Commons.chat_async.md#commons.Commons.chat_async), [stream()](Commons.stream.md#commons.Commons.stream), [chat_structured()](Commons.chat_structured.md#commons.Commons.chat_structured), etc.) are disabled and raise `NotImplementedError`s because they are not (yet) tied in to the commons framework. The rest of chatlas's surface works as it does on any chat.

`data_sources` is a [DataSource](DataSource.md#commons.DataSource), or a mapping of name to [DataSource](DataSource.md#commons.DataSource); a measure can take a named source's connection as an argument named after it. `instructions` is extra text placed under an `## Additional instructions` heading at the end of commons' built-in system prompt, as a string or the path to a text or Markdown file.

Construction raises a TypeError if `client` is not a `chatlas.Chat`, if an entry of `data_sources` is not a [DataSource](DataSource.md#commons.DataSource), or if a layer is not the layer its argument claims; a ValueError if `data_sources` names no source or a measure asks for an injection no named source can fill; and a FileNotFoundError if `instructions` names a file that does not exist.
