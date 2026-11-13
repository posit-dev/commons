# commons (development version)

* The `run_r` worker reads no R startup files, so variables set in a `.Renviron` file, like API keys, stay out of reach of model-written code.

* `describe_table` works on SQL Server, Oracle, and other databases whose SQL has no `LIMIT` clause (#468).

* `trajectory_review()` has been removed. The coding-agent skill provides guidance for building interactive reviews and trust-over-time plots from `trajectory_read()` output.

* `data_source()` errors when a `dictionary` file has no top-level `tables` field, rather than silently loading an empty dictionary (#473).

* `data_source()` imports Databricks metric views from Unity Catalog through ODBC. It previously listed them as plain views and could not read their definitions (#496).

* `describe_table` shows at most 50 columns and reports how many additional columns it omits, keeping wide-table descriptions compact. Columns documented in the data dictionary are shown first. The system prompt no longer limits the agent to columns that `describe_table` or `search_context` confirmed (#475).

* `describe_table` describes any table the connection can query, not only the data source's tables, so it agrees with `run_sql`. The result notes when a table is outside the data source. Agents in `mode = "trusted only"` still describe only the data source's tables (#469).

* `data_source()` given a DBI connection and no `tables` selects the tables and views in the connection's current schema. When that schema has too many tables to list in the system prompt, the agent finds them with `search_catalog` instead, as for Snowflake and Databricks connections. A `DBI::Id` naming only a schema, like `DBI::Id(schema = "marts")`, selects every table and view in that schema. A data dictionary can name those tables relatively, like `orders` for `marts.orders`, when the name matches only one selected table.

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

* Agents write reports as Quarto documents. In `commons_server()`, a document
  streams into the chat's drawer as the agent writes it, with each R cell
  knitted in a sandboxed R session as soon as it arrives. Documents get their
  data by calling `commons()` methods in their code, and the agent revises them
  with a new `edit_artifact` tool.

* `describe_table` reports table schemas and documentation without a sampled-row summary. DuckDB descriptions use database-native types. Snowflake and Databricks continue to use native metadata, while other DBI connections infer R column classes from five sampled rows, or zero rows in trusted-only mode (#319).

* `trajectory_read()` now returns a `user` field with the originating Shiny session username supplied by Connect. With `log = TRUE`, authenticated session users are recorded with conversation trajectories; older logs and anonymous sessions return `NA_character_` (#316).

* On macOS, R code run by `run_r` can now start other programs, such as through `system()` or `system2()`. The sandbox previously stopped every program it started. Those programs run under the same sandbox as the R session.

* R code run by `run_r` can no longer send a signal to the application process's ID or to its process group. On Linux, the programs it starts can also no longer leave its process group, so they all stop when the R session ends.

* The CSS classes on `run_r`'s display are now `commons-run-display`, `commons-run-details`, `commons-run-code`, and `commons-run-plot`, without the `-r`, because the Python package's code tool uses the same classes. App CSS that targets the old `commons-run-r-*` names needs updating.

* On Posit Connect, users can now share conversations, documents, plots, or tables as static content they own. Existing apps need no changes to enable this feature. A shared plot or table includes the code that made it, the date it was created, and a link back to the original agent. To turn sharing on, add Connect's "Connect Visitor API Key" integration to the app under **Runtime** > **Integrations** in its settings.

# commons 0.1.1

* Fixes an issue with the R code sandbox where the generated policy would be
  too long when there were thousands of R packages installed.

* A number of improvements to documentation.

# commons 0.1.0

* Initial release.
