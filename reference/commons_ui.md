# Shiny chat UI and server for commons agents

These functions wrap
[`shinychat::chat_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_ui.html)
and
[`shinychat::chat_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html)
for commons agents. The server verifies each `<commons-citation>` the
model writes against its own context, measure definitions, and data
documentation as the answer streams, and rewrites verified citations
inline as numbered, server-authored `<shiny-aside>` elements. Citation
details name the trusted source. A compact provenance aside follows the
answer when it was produced by a governed calculation, or when a
fallback answer cites nothing verified.

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
