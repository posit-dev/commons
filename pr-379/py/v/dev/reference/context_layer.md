## context_layer()


Create a context layer from text or Markdown files.


Usage

``` python
context_layer(files=())
```


`files` must be a collection of paths; a bare string or path raises `TypeError`. Files are read eagerly and decoded as UTF-8, so a missing path (`FileNotFoundError`), a directory (`IsADirectoryError`), or a file in another encoding (`UnicodeDecodeError`) fails here rather than mid-conversation.
