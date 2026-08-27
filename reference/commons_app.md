# Shiny chat app for a commons agent

`commons_app()` composes
[`commons_server()`](https://posit-dev.github.io/commons/reference/commons_server.md)
and
[`commons_theme()`](https://posit-dev.github.io/commons/reference/commons_server.md)
into a complete app for local development. To customize and deploy the
Shiny app, assemble the UI and server yourself with
[`commons_theme()`](https://posit-dev.github.io/commons/reference/commons_server.md)
and
[`commons_server()`](https://posit-dev.github.io/commons/reference/commons_server.md).

## Usage

``` r
commons_app(client, ...)
```

## Arguments

- client:

  A
  [`commons()`](https://posit-dev.github.io/commons/reference/commons.md)
  agent.

- ...:

  Extra arguments passed to
  [`shiny::shinyApp()`](https://rdrr.io/pkg/shiny/man/shinyApp.html).

## Value

A [`shiny::shinyApp()`](https://rdrr.io/pkg/shiny/man/shinyApp.html)
object.

## Citations and provenance

The server verifies each `<commons-citation>` the model writes against
its own context, measure definitions, and data documentation as the
answer streams, and rewrites verified citations inline as numbered,
server-authored `<shiny-aside>` elements. Citation details name the
trusted source. A provenance marker in a compact `<shiny-aside>` follows
the answer when it was produced by a trusted calculation, or when a
fallback answer cites nothing verified.

## Examples

``` r
if (FALSE) { # \dontrun{
agent <- commons(
  ellmer::chat_anthropic(),
  data_sources = data_source(sales = sales)
)
commons_app(agent)
} # }
```
