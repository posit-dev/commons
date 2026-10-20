## ui.app()


Build a complete app around a commons agent.


Usage

``` python
ui.app(
    client,
    *,
    toolbar=True,
    **kwargs,
)
```


Every session the app serves shares the one agent passed here via `client`: a second visitor joins the first one's conversation, and two questions answered at once interleave the agent's citation and provenance state, so neither answer can be trusted. To give each session its own agent, assemble the page and the server yourself with [commons.ui.theme()](ui.theme.md#commons.ui.theme) and [commons.ui.server()](ui.server.md#commons.ui.server), building the agent inside the server function.


## Parameters


`client: Commons`  
A commons agent.

`toolbar: bool = ``True`  
Whether to show the development toolbar, a dark-mode switch.

`**kwargs: Any`  
Passed to `shiny.App()`.
