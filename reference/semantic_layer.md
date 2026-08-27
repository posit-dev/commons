# Create a semantic layer

`semantic_layer()` collects governed R measures for a
[`commons()`](https://posit-dev.github.io/commons/reference/commons.md)
agent. Data dictionary definitions and warehouse semantic models
contribute through
[`data_source()`](https://posit-dev.github.io/commons/reference/data_source.md).

## Usage

``` r
semantic_layer(...)
```

## Arguments

- ...:

  [`measure()`](https://posit-dev.github.io/commons/reference/measure.md)
  objects, lists of measures, or paths to R scripts or directories
  containing R scripts. Directory searches are not recursive. File and
  inline measures can be freely mixed.

## Value

A `commons_semantic_layer` object.

## Measures from files

Character paths can name R scripts or directories containing them.
Functions marked with `@measure` become measures; other functions in
those files can be used as helpers.

The roxygen title, description, and `@return` text describe the measure.
Each `@param` marks a model-supplied argument and can declare its type:
`string`, `integer`, `number`, `boolean`, `enum[value, ...]`, or an
array such as `string[]`. Without a declaration, commons infers the type
from the default, falling back to `string`.

Measure and helper source is visible in `run_r`; evaluating a measure's
name there prints its definition. Function environments, connections,
and credentials are not shared with that session.

## Measure arguments

A measure function can take two kinds of arguments:

- Arguments documented with `@param` (or listed in `arguments`, for
  inline
  [`measure()`](https://posit-dev.github.io/commons/reference/measure.md)s)
  are supplied by the model.

- Undocumented arguments are supplied by
  [`commons()`](https://posit-dev.github.io/commons/reference/commons.md)
  when the measure runs. An argument named after a data source receives
  its connection, even if the argument has a default. Any other
  undocumented argument keeps its default; if it has no default,
  [`commons()`](https://posit-dev.github.io/commons/reference/commons.md)
  errors. The model never sees these arguments.

This means a measure can take the connection it needs as an argument
rather than relying on a variable defined elsewhere, and you can create
a semantic layer before connecting to a database.

For objects that aren't data sources, such as a pins board or an API
client, give the argument a default that builds the object, e.g.
`board = pins::board_connect()`. Write the default as a call rather than
a reference to a variable defined elsewhere, so the measure doesn't
depend on where the semantic layer is created.

## See also

[`measure()`](https://posit-dev.github.io/commons/reference/measure.md)
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
#> <environment: 0x555bb94935b0>
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
