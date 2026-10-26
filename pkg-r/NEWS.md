# commons (development version)

* The `commons()` function was split into two. Calls to `commons()` previously looked like this:

  ```r
  commons <- commons(client, data_sources, semantic_layer, context_layer)
  ```

  The construction of the data structure that holds the data sources, semantic layer, and context layer and the construction of the agent harness that makes that information available to an LLM are now split into two pieces.

  ```r
  commons <- commons(data_sources = ..., semantic_layer = ..., context_layer = ...)
  agent <- agent(client, commons = commons)
  ```

  We call that first data structure "the commons." The commons can be used to invoke trusted code and search trusted context directly from R and is intended for use with other coding agents. See `?commons()` to learn more. `agent()` returns what `commons()` used to return—a commons agent.

  This transition was implemented backward-compatibly; existing calls to `commons()` will raise a deprecation warning with migration instructions.

* `agent()` (formerly `commons()`) gains a `mode` argument. With `mode = "trusted only"`, the agent answers only with trusted calculations. It never writes its own SQL or R, and it tells the user when no trusted calculation answers a question. These answers carry no provenance markers.

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
