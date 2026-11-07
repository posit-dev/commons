## DataSource.ensure_tables_loaded()


Read the pins behind `tables` that this source has not read yet.


Usage

``` python
DataSource.ensure_tables_loaded(tables)
```


For a caller that reads a table's columns from the backend rather than through [query()](DataSource.query.md#commons.DataSource.query), which is where loading otherwise happens. `source_ensure_tables()` in `pkg-r/R/data-source.R` is the same step.
