## DataSource.from_board()


Expose a pins board's pins as tables, each read on first use.


Usage

``` python
DataSource.from_board(
    board,
    tables,
    dictionary=None,
)
```


`dictionary` is taken here so that the argument survives the dispatcher; a board has no catalog listing to fold into it. Its governed definitions are lowered at the end of construction, once the dialect and the final table set are known.
