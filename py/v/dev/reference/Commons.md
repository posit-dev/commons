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
    instructions=None,
    network="none",
    log=False,
    share_with=None
)
```


Given a `chatlas.Chat` for the provider and model, the data sources it can query, and optionally a semantic layer of trusted calculations and a context layer of prose, a [Commons](Commons.md#commons.Commons) agent will allow for agent interactions with answers classified by how they were produced.

A [Commons](Commons.md#commons.Commons) agent inherits directly from `chatlas.Chat` and relies on the chatlas infrastructure to set up the LLM provider and model. [Commons](Commons.md#commons.Commons) initializes its own chat state and system prompt to ensure provenance and citation tracking. Passing a custom system prompt in the [Commons](Commons.md#commons.Commons) constructor is ignored with a warning; use `instructions` to add to commons' prompt instead. For best results, enable thinking where the provider and model support it.

[chat()](Commons.chat.md#commons.Commons.chat) and [stream_async()](Commons.stream_async.md#commons.Commons.stream_async) are the currently supported ways to interact with a [Commons](Commons.md#commons.Commons) agent. The other entry points chatlas offers ([chat_async()](Commons.chat_async.md#commons.Commons.chat_async), [stream()](Commons.stream.md#commons.Commons.stream), [chat_structured()](Commons.chat_structured.md#commons.Commons.chat_structured), etc.) are disabled and raise `NotImplementedError`s because they are not (yet) tied in to the commons framework. The rest of chatlas's surface works as it does on any chat.

`data_sources` is a [DataSource](DataSource.md#commons.DataSource), or a mapping of name to [DataSource](DataSource.md#commons.DataSource); a measure can take a named source's connection as an argument named after it. `instructions` is extra text placed under an `## Additional instructions` heading at the end of commons' built-in system prompt, as a string or the path to a text or Markdown file.

The agent can run Python code that its model writes. The code runs in a separate, sandboxed Python process, which starts the first time the model runs code. `network` sets whether that process can reach the network: `"none"` (the default) or `"full"`. The sandbox works on Linux and macOS. For local development on another system, set the `COMMONS_ALLOW_UNSAFE_FALLBACK` environment variable to run the code with limited checks instead. Warning! These checks are not intended to be a security boundary.

`log` requests trajectory capture with OpenTelemetry (default `False`). It needs the `tracing` extra (`pip install 'commons[tracing]'`), and warns without it. On Posit Connect, the agent warns when the server cannot record trajectories, and turns on the content's Content Observability setting when the process is not yet traced. Connect must be \>= 2026.09.0, with `OpenTelemetry.Enabled` and `OpenTelemetry.AllowContentInstrumentation` set to `true` by a server administrator. Elsewhere, the agent records only when a tracer provider is already installed. Logging also records the authenticated Shiny session user, when Connect supplies one, for attribution. `share_with` is a sequence of Connect usernames granted access to this content's trajectories once logging is live. Reading traces needs editor-level access, so the named users are added as collaborators on the content, which is a wider grant than trace access. They need an account that can publish. `share_with` applies only when `log=True`.

Construction raises a TypeError if `client` is not a `chatlas.Chat`, if `log` is not a bool, if `share_with` is not a sequence of strings, if an entry of `data_sources` is not a [DataSource](DataSource.md#commons.DataSource), or if a layer is not the layer its argument claims; a ValueError if `data_sources` names no source, a measure asks for an injection no named source can fill, or `network` is neither `"none"` nor `"full"`; a FileNotFoundError if `instructions` names a file that does not exist; and a RuntimeError if this host cannot sandbox the session and the opt-in is not set.
