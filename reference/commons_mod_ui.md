# Shiny module for commons agents

These functions wrap
[`shinychat::chat_mod_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html)
and
[`shinychat::chat_mod_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html)
with commons-specific answer provenance UI. Answers produced from
registered measures get a compact verified-answer pill. Answers produced
from fallback SQL get a caution pill.

## Usage

``` r
commons_mod_ui(id, ..., messages = NULL, height = "100%")

commons_mod_server(
  id,
  client,
  bookmark_on_input = TRUE,
  bookmark_on_response = TRUE
)
```

## Arguments

- id:

  Module ID.

- ...:

  Arguments passed to
  [`shinychat::chat_mod_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html)
  or
  [`shinychat::chat_mod_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html).

- messages:

  Initial messages shown in the chat. Passed to
  [`shinychat::chat_mod_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html).

- height:

  Chat container height. Defaults to `"100%"` so the chat input stays
  docked at the bottom of fill layouts.

- client:

  A
  [`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
  agent. Create a new agent for each Shiny session.

- bookmark_on_input, bookmark_on_response:

  Whether to add Shiny bookmarking hooks for user inputs and assistant
  responses.

## Value

`commons_mod_ui()` returns UI. `commons_mod_server()` returns the
shinychat module server result.

## Examples

``` r
if (FALSE) { # \dontrun{
library(shiny)

ui <- page_fillable(
  commons_mod_ui("chat")
)

server <- function(input, output, session) {
  agent <- commons(
    ellmer::chat_anthropic(),
    data_sources = data_source(sales = sales)
  )
  commons_mod_server("chat", agent)
}

shinyApp(ui, server)
} # }
```
