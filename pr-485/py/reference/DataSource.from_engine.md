## DataSource.from_engine()


Query a caller's database directly. Nothing is copied.


Usage

``` python
DataSource.from_engine(
    engine,
    tables=None,
    exclude=None,
    dictionary=None,
)
```


A Snowflake or Databricks engine imports its catalog: the selection is resolved against the warehouse, access to it is verified for the current principal, and what it reports is folded into `dictionary`.

With `tables` unset on any other backend, its own listing is taken as given: it reports what exists, so there is nothing to check and no round trip worth paying for.

`exclude` takes unqualified object-name globs to drop from a warehouse catalog listing, such as `"TMP_*"`. Only a warehouse has a listing to drop from, so any other engine refuses it.

On a warehouse `dictionary` is taken here because the catalog listing is folded into it during construction; on any other engine it is simply attached. Its governed definitions are lowered once the dialect and the final table set are known, at the end of construction.
