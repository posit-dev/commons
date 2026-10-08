## data_source()


Create a data source from an engine, a pins board, or named frames.


Usage

``` python
data_source(
    *args,
    tables=None,
    exclude=None,
    dictionary=None,
    **frames,
)
```


A thin dispatcher over the constructors, which are the documented way in.

`tables`, `exclude`, and `dictionary` are keyword-only options, so all three names are reserved in every form: a frame passed under one of them is rejected with a TypeError naming it, never silently consumed. `tables` selects tables of the engine and board forms, `exclude` drops relations from a warehouse catalog listing by glob, and `dictionary` attaches a data dictionary to any form. To use one as a frame name, call [DataSource.from_frames()](DataSource.from_frames.md#commons.DataSource.from_frames) directly.

A dictionary's governed definitions are compiled for the source's dialect during construction, so construction raises if the dialect has no emitter (DuckDB, Snowflake, and Databricks have one), if a definition sits on a table the source does not expose, or if a metric mixes row and aggregate grain. On a warehouse the authored column spellings are bound to the names the catalog reported before anything is lowered, so it raises there only if a table declaring definitions matched no exposed relation, or if a definition names an authored column the selected relation does not have.
