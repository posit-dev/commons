## DataSource


Tables an agent can query, and the dictionary that describes them.


Usage

``` python
DataSource(
    backend,
    tables,
    table_ids=dict(),
    pending=None,
    dictionary=None,
    relations=None,
    manifest=None,
    session=None,
    definition_bindings=None,
    semantic_models=dict(),
    semantic_stubs=dict()
)
```


## Parameter Attributes


`backend: Backend`  

`tables: list[str]`  

`table_ids: dict[str, TableId] = dict()`  

`pending: _PendingPins | None = None`  

`dictionary: DataDictionary | None = None`  

`relations: dict[str, Relation] | None = None`  

`manifest: Manifest | None = None`  

`session: SessionSnapshot | None = None`  

`definition_bindings: dict[str, Any] | None = None`  

`semantic_models: dict[str, SemanticModel] = dict()`  

`semantic_stubs: dict[str, SemanticStub] = dict()`
