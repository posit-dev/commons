# Create a semantic layer

A semantic layer is a collection of governed measures available to a
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
agent.

## Usage

``` r
semantic_layer(...)
```

## Arguments

- ...:

  [`measure()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/measure.md)
  objects, lists of measures, or paths to R scripts or directories. File
  and inline measures can be freely mixed.

## Value

A `commons_semantic_layer` object.

## Details

A measure function can take two kinds of arguments:

- Arguments documented with `@param` (or listed in `arguments`, for
  inline
  [`measure()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/measure.md)s)
  are supplied by the model.

- Undocumented arguments are supplied by
  [`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
  when the measure runs. An argument named after a data source receives
  its connection, even if the argument has a default. Any other
  undocumented argument keeps its default; if it has no default,
  [`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
  errors. The model never sees these arguments.

This means a measure can take the connection it needs as an argument
rather than relying on a variable defined elsewhere, and you can create
a semantic layer before connecting to a database.

For objects that aren't data sources, such as a pins board or an API
client, give the argument a default that builds the object, e.g.
`board = pins::board_connect()`. Write the default as a call rather than
a reference to a variable defined elsewhere, so the measure doesn't
depend on where the semantic layer is created.

The source of each measure, and of any helper functions defined
alongside it in the semantic layer's files, is readable in the agent's
`run_r` session: evaluating a measure's name there prints its
definition. Only source text is shared with that session; the functions'
environments (and any connections or credentials in them) are not.

## See also

[`measure()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/measure.md)
to define a measure.

## Examples

``` r
semantic_layer(
  measure(
    "order_count",
    "Count of orders.",
    function() 10,
    arguments = list()
  )
)
#> $measures
#> $measures$order_count
#> # <ellmer::ToolDef> order_count()
#> # @name: order_count
#> # @description: Count of orders.
#> # @convert: TRUE
#> #
#> function () 
#> 10
#> <environment: 0x55dc297e0748>
#> 
#> 
#> $fn_sources
#>        order_count 
#> "function () \n10" 
#> 
#> attr(,"class")
#> [1] "commons_semantic_layer"

if (FALSE) { # \dontrun{
# In R/semantic_layer.R, `warehouse` has no @param, so commons supplies it:
#
# #' @param region `string` The sales region.
# #' @measure
# revenue <- function(region, warehouse) {
#   DBI::dbGetQuery(warehouse, ...)
# }

agent <- commons(
  ellmer::chat_anthropic(),
  data_sources = list(warehouse = data_source(DBI::dbConnect(...))),
  semantic_layer = semantic_layer("R/semantic_layer.R")
)
} # }
```
