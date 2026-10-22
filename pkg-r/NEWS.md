# commons (development version)

* A Snowflake semantic view's variables are now bound with the type the view declares, such as `NUMBER(10,2)`. Snowflake refuses a value of another type, and an ODBC driver can bind a number as text (#447).

* A Snowflake semantic view whose base tables are named with quoted identifiers, such as `"orders"`, now scopes to those tables. The quotes were kept as part of each name, so `data_source()` could not find them (#446).

* A definition that adds `NULL` to a date, such as `created + NULL`, now compiles to SQL that Snowflake accepts. It compiles to a typed `NULL` timestamp (#441).

* A definition that divides by a compound expression, such as `amount / (ratio * 2)`, now compiles to the correct Snowflake and Databricks SQL. The parentheses around the divisor were dropped, so the query divided by `ratio` alone (#439).

* `commons()` gains a `mode` argument. With `mode = "trusted only"`, the agent answers only with trusted calculations. It never writes its own SQL or R, and it tells the user when no trusted calculation answers a question. These answers carry no provenance markers.

* `describe_table` reports complete table schemas and documentation without a sampled-row summary. DuckDB descriptions use database-native types. Snowflake and Databricks continue to use native metadata, while other DBI connections infer R column classes from five sampled rows, or zero rows in trusted-only mode (#319).

* On macOS, R code run by `run_r` can now start other programs, such as through `system()` or `system2()`. The sandbox previously stopped every program it started. Those programs run under the same sandbox as the R session.

* R code run by `run_r` can no longer send a signal to the application process's ID or to its process group. On Linux, the programs it starts can also no longer leave its process group, so they all stop when the R session ends.

* The CSS classes on `run_r`'s display are now `commons-run-display`, `commons-run-details`, `commons-run-code`, and `commons-run-plot`, without the `-r`, because the Python package's code tool uses the same classes. App CSS that targets the old `commons-run-r-*` names needs updating.

# commons 0.1.1

* Fixes an issue with the R code sandbox where the generated policy would be
  too long when there were thousands of R packages installed.

* A number of improvements to documentation.

# commons 0.1.0

* Initial release.
