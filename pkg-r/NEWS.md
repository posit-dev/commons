# commons (development version)

* The system prompt now tells the agent to render a chart only when no trusted calculation already answers the question, rather than running code to visualize a result it has already been given.

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
