# Create a measure

A measure is a trusted calculation inside a
[`semantic_layer()`](https://posit-dev.github.io/commons/reference/semantic_layer.md).
Its function body is ordinary R; its `arguments` schema tells the model
what inputs it can supply.

## Usage

``` r
measure(name, description, fn, arguments = list(), title = NULL)
```

## Arguments

- name:

  Measure name.

- description:

  What the measure computes.

- fn:

  Function that computes the measure.

- arguments:

  A named list of
  [`ellmer::type_string()`](https://ellmer.tidyverse.org/reference/type_boolean.html)
  and friends describing the arguments the model supplies. Arguments of
  `fn` not listed here are hidden from the model: they receive a
  matching data source's connection or keep their defaults. See
  [`semantic_layer()`](https://posit-dev.github.io/commons/reference/semantic_layer.md).

- title:

  Human-readable measure title to show in user interfaces. If `NULL`, a
  title is derived from `name`.

## Value

A measure object.

## Details

Two return types receive special display handling: ggplots and
[`gt::gt()`](https://gt.rstudio.com/reference/gt.html) tables are shown
directly to the user in the opened measure result. The model is told
that the plot or table has already been shown, so it can interpret the
result without repeating it.

For full control over a result, `fn` can return an
[ellmer::ContentToolResult](https://ellmer.tidyverse.org/reference/Content.html).
Its `value` is sent to the model and its `extra$display` controls the
shinychat display. When the display includes HTML, Markdown, or text,
the model is told that the result is already visible to the user. An
optional `extra$data` value is made available to `run_r` and removed
from the result before it is returned to ellmer.

## See also

[`semantic_layer()`](https://posit-dev.github.io/commons/reference/semantic_layer.md)
to collect measures into a layer.

## Examples

``` r
table <- data.frame(term = c("Headache", "Nausea"), count = c(7, 5))
table_measure <- measure(
  "adverse_events",
  "Summarize adverse events.",
  function() {
    ellmer::ContentToolResult(
      value = "Headache: 7; Nausea: 5",
      extra = list(
        display = shinychat::tool_result_display(
          html = paste0(
            "<table><tr><td>Headache</td><td>7</td></tr>",
            "<tr><td>Nausea</td><td>5</td></tr></table>"
          )
        ),
        data = table
      )
    )
  }
)
```
