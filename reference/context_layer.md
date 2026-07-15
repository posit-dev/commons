# Create a context layer

A context layer contains text that helps a
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
agent interpret its data source.

## Usage

``` r
context_layer(files = character(), always = character())
```

## Arguments

- files:

  Character vector of paths to text/markdown files to index.

- always:

  Character vector of facts to inject into the system prompt on every
  turn. Optional.

## Value

A `commons_context_layer` object.

## Details

Files are chunked and indexed with ragnar when the agent first searches
its context. The `always` argument is for short facts that should be
included in every system prompt.

## Examples

``` r
layer <- context_layer(
  always = "Revenue excludes tax unless stated otherwise."
)
```
