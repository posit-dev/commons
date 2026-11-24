## Exchange


One exchange of a conversation: a user's question and the turns that answer it.


Usage

``` python
Exchange(
    turns,
    tag,
    decisions,
)
```


`turns` starts with the user's turn and runs to the turn before the next question. They are the same `Turn` objects as in `Trajectory.turns`. `tag` is the answer's provenance tag, or None when none was recorded. `decisions` are the [CitationDecision](CitationDecision.md#commons.CitationDecision)s recorded for the answer.


## Parameter Attributes


`turns: list[Turn]`  

`tag: Tag | None`  

`decisions: list[CitationDecision]`
