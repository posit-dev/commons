# Shiny chat UI and server for commons agents

These functions wrap
[`shinychat::chat_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_ui.html)
and
[`shinychat::chat_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html)
with commons-specific answer provenance UI. Answers produced from
registered measures get a compact verified-answer pill. Answers produced
from fallback SQL or R can cite text from the agent's context, measure
definitions, or data documentation; verified citations render as
footnotes whose tooltips name their source. Fallback answers with no
verified citation get a potentially-untrusted caution pill.

## Usage

``` r
commons_ui(id, ..., messages = NULL, height = "100%")

commons_server(id, client)
```

## Arguments

- id:

  The ID of the chat element; must match between `commons_ui()` and
  `commons_server()`.

- ...:

  Extra HTML attributes passed to
  [`shinychat::chat_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_ui.html).

- messages:

  Initial messages shown in the chat. Passed to
  [`shinychat::chat_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_ui.html).

- height:

  Chat container height. Defaults to `"100%"` so the chat input stays
  docked at the bottom of fill layouts.

- client:

  A
  [`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
  agent. Create a new agent for each Shiny session.

## Value

`commons_ui()` returns UI. `commons_server()` returns the
[`shinychat::chat_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html)
result.

## Examples

``` r
if (FALSE) { # \dontrun{
library(shiny)

ui <- page_fillable(
  commons_ui("chat")
)

server <- function(input, output, session) {
  agent <- commons(
    ellmer::chat_anthropic(),
    data_sources = data_source(sales = sales)
  )
  commons_server("chat", agent)
}

shinyApp(ui, server)
} # }
```
