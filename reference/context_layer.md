# Create a context layer

A context layer contains text that helps a
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
agent interpret its data source.

## Usage

``` r
context_layer(files = character())
```

## Arguments

- files:

  Character vector of paths to text/markdown files to index.

## Value

A `commons_context_layer` object.

## Details

Files are chunked and indexed with ragnar when the agent first searches
its context. Facts that should be in every prompt belong in the
`instructions` passed to
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md),
not here.

## Examples

``` r
path <- tempfile(fileext = ".md")
writeLines("Revenue excludes tax unless stated otherwise.", path)
layer <- context_layer(files = path)
```
