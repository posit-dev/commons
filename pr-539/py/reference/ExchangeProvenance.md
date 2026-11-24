## ExchangeProvenance


The provenance of one exchange: a user's question and the turns that answer it.


Usage

``` python
ExchangeProvenance(
    tag,
    decisions,
)
```


`tag` is the answer's provenance tag, or None when none was recorded. `decisions` are the [CitationDecision](CitationDecision.md#commons.CitationDecision)s recorded for the answer.


## Parameter Attributes


`tag: Tag | None`  

`decisions: list[CitationDecision]`
