## ui.theme()


Build the theme a commons chat page uses.


Usage

``` python
ui.theme(
    preset="shiny",
    **variables,
)
```


Layers the commons chat variables over `shinychat.page_chat_theme()` and attaches the dependency serving the chat script, stylesheet and icons.


## Parameters


`preset: str | None = ``"shiny"`  
A Shiny or Bootswatch preset name.

`**variables: str | float | bool | None`  
Sass-variable overrides, in either `snake_case` or `kebab-case`. These win over the commons defaults.
