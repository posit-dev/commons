## measure()


Mark a function as a measure.


Usage

``` python
measure(
    *,
    description=None,
    name=None,
    title=None,
    provenance=(),
)
```


The decorated function is returned unchanged, so measures and the helpers they call stay ordinary callables. Model-supplied arguments are expected to be scalars, enums, or arrays of those; richer shapes are not rejected, but the schema block renders them only approximately.

`provenance` records links back to wherever the measure's definition came from. The R implementation attaches provenance through a roxygen tag instead, and only to measures sourced from a file.
