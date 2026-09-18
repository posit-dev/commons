## SemanticLayer


The trusted calculations an agent can run.


Usage

``` python
SemanticLayer(
    measures,
    source_text,
)
```


`source_text` holds the source of the measures and the module-level helpers they call, keyed by Python function name. Only text is kept: the agent's worker session reads measure definitions but never receives a callable. Two functions that share a Python name share one entry, and the first definition collected wins, so a measure whose function shares its name with an earlier one is shown that earlier function's source instead. The R implementation sources a path's files into one shared environment, so there the last definition of a same-named helper wins instead, and is what every measure calling it actually runs.

The layout of this object is internal and may change without notice.


## Parameter Attributes


`measures: Mapping[str, Measure]`  

`source_text: Mapping[str, str]`
