# Shiny chat UI and server for commons agents

`commons_app()` is a convenience for running a commons agent locally or
in a single-user Shiny app. For a multi-user app, combine `commons_ui()`
and `commons_server()`, creating a new agent inside the server function
for each session.

## Usage

``` r
commons_app(client, ...)

commons_ui(id, ...)

commons_server(id, client, ...)
```

## Arguments

- client:

  A
  [`commons()`](https://posit-dev.github.io/commons/reference/commons.md)
  agent. `commons_app()` uses one agent for the lifetime of its local or
  single-user app. In a multi-user app, create an agent inside the app's
  server function and pass it to `commons_server()`. This gives each
  Shiny session its own agent state.

- ...:

  In `commons_app()`, extra arguments passed to
  [`shiny::shinyApp()`](https://rdrr.io/pkg/shiny/man/shinyApp.html). In
  `commons_ui()`, extra arguments passed to
  [`shinychat::chat_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_ui.html).
  In `commons_server()`, arguments passed to
  [`shinychat::chat_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html).

- id:

  The ID of the chat element; must match between `commons_ui()` and
  `commons_server()`.

## Value

`commons_app()` returns a
[`shiny::shinyApp()`](https://rdrr.io/pkg/shiny/man/shinyApp.html)
object. `commons_ui()` returns UI. `commons_server()` returns the
[`shinychat::chat_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html)
result.

## Details

These functions wrap
[`shinychat::chat_app()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html),
[`shinychat::chat_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_ui.html),
and
[`shinychat::chat_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html)
for commons agents. The server verifies each `<commons-citation>` the
model writes against its own context, measure definitions, and data
documentation as the answer streams, and rewrites verified citations
inline as numbered, server-authored `<shiny-aside>` elements. Citation
details name the trusted source. A provenance marker in a compact
`<shiny-aside>` follows the answer when it was produced by a governed
calculation, or when a fallback answer cites nothing verified.

## Examples

``` r
if (FALSE) { # \dontrun{
# Local or single-user app
agent <- commons(
  ellmer::chat_anthropic(),
  data_sources = data_source(sales = sales)
)
commons_app(agent)

# Multi-user Shiny app
library(shiny)

ui <- bslib::page_fillable(
  commons_ui("chat")
)

server <- function(input, output, session) {
  session_agent <- commons(
    ellmer::chat_anthropic(),
    data_sources = data_source(sales = sales)
  )
  commons_server("chat", session_agent)
}

shinyApp(ui, server)
} # }
```
