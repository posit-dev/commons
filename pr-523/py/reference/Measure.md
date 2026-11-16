## Measure


A trusted calculation the agent can run.


Usage

``` python
Measure(
    name,
    title,
    description,
    func,
    params,
    injected=(),
    provenance=(),
)
```


`params` describes only the arguments the model supplies; `injected` names the arguments commons supplies, which the model never sees.


## Parameter Attributes


`name: str`  

`title: str`  

`description: str`  

`func: Callable[…, Any]`  

`params: type[BaseModel]`  

`injected: tuple[str, …] = ()`  

`provenance: tuple[str, …] = ()`  


## Methods

| Name | Description |
|----|----|
| [validate_args()](#validate_args) | Check and coerce the model's arguments against the schema. |

------------------------------------------------------------------------


#### validate_args()


Check and coerce the model's arguments against the schema.


Usage

``` python
validate_args(args)
```


The provider only ever sees `call_measure`, so a measure's own arguments arrive unchecked and are validated here.
