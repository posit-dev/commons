## CitationDecision


One citation in an answer, and whether its quote was verified.


Usage

``` python
CitationDecision(
    quote,
    status,
    label=None,
    kind=None,
)
```


`status` is `"accepted"` when the quote, after normalization, is found in the trusted text the agent was given (its documentation, measure definitions, and data dictionaries), and `"rejected"` when it is not or is too short to check. It is `"malformed"` when the citation does not have exactly one block quote, so there is no quote to check. `quote` is the quoted text, or None for a malformed citation. `label` names the trusted source that matched an accepted quote, and `kind` says what sort of source it is: `"prose"`, `"definition"`, or `"schema"`. Both are None unless the status is accepted.

The agent records each decision to the `commons.citation.candidates` span attribute, and [trajectory_read()](trajectory_read.md#commons.trajectory_read) returns them in `ExchangeProvenance.decisions`.


## Parameter Attributes


`quote: str | None`  

`status: CitationStatus`  

`label: str | None = None`  

`kind: CitationKind | None = None`  


## Methods

| Name | Description |
|----|----|
| [as_record()](#as_record) | Serialize a citation decision. |

------------------------------------------------------------------------


#### as_record()


Serialize a citation decision.


Usage

``` python
as_record()
```
