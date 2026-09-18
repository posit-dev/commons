## ContextLayer


Text that helps an agent interpret its data source.


Usage

``` python
ContextLayer(docs=())
```


Construct one with [context_layer()](context_layer.md#commons.context_layer). Internals are private and may change without notice.


## Attributes

| Name | Description |
|----|----|
| [docs](#docs) | The documents as read from their files, frontmatter stripped. |

------------------------------------------------------------------------


#### docs


The documents as read from their files, frontmatter stripped.


`docs: tuple[str, …]`


## Methods

| Name | Description |
|----|----|
| [prewarm()](#prewarm) | Build the index now so the first search does not pay for it. |
| [search()](#search) | Retrieve the chunks most relevant to [query](DataSource.query.md#commons.DataSource.query). |

------------------------------------------------------------------------


#### prewarm()


Build the index now so the first search does not pay for it.


Usage

``` python
prewarm()
```


Optional and idempotent; worth calling when a search is known to be coming, so its cost does not land on the first user turn.


------------------------------------------------------------------------


#### search()


Retrieve the chunks most relevant to [query](DataSource.query.md#commons.DataSource.query).


Usage

``` python
search(query, top_k=3)
```


Returns chunk texts, best match first, at most `top_k` of them. An empty layer, or a query nothing matches, returns an empty list. `top_k` must be at least 1.
