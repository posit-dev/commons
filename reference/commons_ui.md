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
verified citation get an untrusted caution pill.

## Usage

``` r
commons_ui(id, ...)

commons_server(id, client, ...)
```

## Arguments

- id:

  The ID of the chat element; must match between `commons_ui()` and
  `commons_server()`.

- ...:

  In `commons_ui()`, extra arguments passed to
  [`shinychat::chat_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_ui.html).
  In `commons_server()`, arguments passed to
  [`shinychat::chat_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html).

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
