# Create a measure

A measure is a governed calculation inside a
[`semantic_layer()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/semantic_layer.md).
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
  [`semantic_layer()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/semantic_layer.md).

- title:

  Human-readable measure title to show in user interfaces. If `NULL`, a
  title is derived from `name`.

## Value

A measure object.

## See also

[`semantic_layer()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/semantic_layer.md)
to collect measures into a layer.
