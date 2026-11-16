## DataSource.ensure_loaded()


Read every pin this source has not read yet.


Usage

``` python
DataSource.ensure_loaded()
```


A board source loads a pin when a query names it, and that recovery lives on [query()](DataSource.query.md#commons.DataSource.query). A measure is handed the connection itself and never goes through [query()](DataSource.query.md#commons.DataSource.query), so nothing there would trigger the read and the measure would fail on a relation that does not exist yet. `source_ensure_all()` in `pkg-r/R/data-source.R` is the same step for the same reason. A source with nothing pending, which is every source that is not board-backed, does nothing.
