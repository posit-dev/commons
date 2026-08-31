# Create a context layer

A context layer contains text that helps a
[`commons()`](https://posit-dev.github.io/commons/reference/commons.md)
agent interpret its data source.

## Usage

``` r
context_layer(files = character())
```

## Arguments

- files:

  Character vector of paths to text or Markdown files.

## Value

A `commons_context_layer` R6 object. Its internals are private and may
change without notice.

## Details

Context is retrieved when relevant. Facts needed in every conversation
belong in the `instructions` passed to
[`commons()`](https://posit-dev.github.io/commons/reference/commons.md),
not here.

## Examples

``` r
path <- tempfile(fileext = ".md")
writeLines("Revenue excludes tax unless stated otherwise.", path)
layer <- context_layer(files = path)
```
