## ui.server()


Wire a commons agent to the chat element `id` on the page.


Usage

``` python
ui.server(
    id,
    client,
    **kwargs,
)
```


Pair this with a page built on [commons.ui.theme()](ui.theme.md#commons.ui.theme), so the chat assets the answers reference are served. In a deployed app, build the agent inside the server function and pass it here, so each session gets its own agent state.

A `client` that is not a commons agent raises `TypeError`: a plain chatlas chat has none of the citation or provenance handling the chat surface renders.


## Parameters


`id: str`  
The id of the chat element on the page.

`client: Commons`  
A commons agent.

`**kwargs: Any`  
Passed to `shinychat.Chat()`.
