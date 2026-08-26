# Chat server and theme for custom commons apps

These are the building blocks for deploying a commons chat as a Shiny
app; for local development, use
[`commons_app()`](https://posit-dev.github.io/commons/reference/commons_app.md).
Pair `commons_server()` with
[`shinychat::page_chat()`](https://posit-dev.github.io/shinychat/r/reference/page_chat.html)
or
[`shinychat::chat_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_ui.html),
passing `theme = commons_theme()` so the commons chat assets are on the
page.

## Usage

``` r
commons_server(id, client, ...)

commons_theme(..., preset = "shiny")
```

## Arguments

- id:

  The ID of the chat element; must match the `id` of the
  [`shinychat::page_chat()`](https://posit-dev.github.io/shinychat/r/reference/page_chat.html)
  or
  [`shinychat::chat_ui()`](https://posit-dev.github.io/shinychat/r/reference/chat_ui.html)
  on the page.

- client:

  A
  [`commons()`](https://posit-dev.github.io/commons/reference/commons.md)
  agent. In a deployed app, create the agent inside the server function
  and pass it to `commons_server()` so each Shiny session gets its own
  agent state.

- ...:

  In `commons_server()`, arguments passed to
  [`shinychat::chat_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html).
  In `commons_theme()`, named Sass variables forwarded to
  [`shinychat::page_chat_theme()`](https://posit-dev.github.io/shinychat/r/reference/page_chat_theme.html).

- preset:

  A bslib or Bootswatch preset name.

## Value

`commons_server()` returns the
[`shinychat::chat_server()`](https://posit-dev.github.io/shinychat/r/reference/chat_app.html)
result. `commons_theme()` returns a
[`bslib::bs_theme()`](https://rstudio.github.io/bslib/reference/bs_theme.html)
object.

## Details

`commons_theme()` bundles the commons chat CSS and JavaScript into an
ordinary
[`bslib::bs_theme()`](https://rstudio.github.io/bslib/reference/bs_theme.html)
(via
[`shinychat::page_chat_theme()`](https://posit-dev.github.io/shinychat/r/reference/page_chat_theme.html)),
so it works anywhere a bslib theme does.

## Examples

``` r
if (FALSE) { # \dontrun{
library(shiny)
library(shinychat)

ui <- page_chat("Assistant", id = "chat", theme = commons_theme())

server <- function(input, output, session) {
  # One agent per session, so each user gets their own agent state
  agent <- commons(
    ellmer::chat_anthropic(),
    data_sources = data_source(sales = sales)
  )
  commons_server("chat", agent)
}

shinyApp(ui, server)
} # }
```
