# Changelog

## commons (development version)

- The
  [`commons()`](https://posit-dev.github.io/commons/r/dev/reference/commons.md)
  function was split into two. Calls to
  [`commons()`](https://posit-dev.github.io/commons/r/dev/reference/commons.md)
  previously looked like this:

  ``` r

  commons <- commons(client, data_sources, semantic_layer, context_layer)
  ```

  The construction of the data structure that holds the data sources,
  semantic layer, and context layer and the construction of the agent
  harness that makes that information available to an LLM are now split
  into two pieces.

  ``` r

  commons <- commons(data_sources = ..., semantic_layer = ..., context_layer = ...)
  agent <- agent(client, commons = commons)
  ```

  We call that first data structure “the commons.” The commons can be
  used to invoke trusted code and search trusted context directly from R
  and is intended for use with other coding agents. See `?commons()` to
  learn more.
  [`agent()`](https://posit-dev.github.io/commons/r/dev/reference/agent.md)
  returns what
  [`commons()`](https://posit-dev.github.io/commons/r/dev/reference/commons.md)
  used to return—a commons agent.

  This transition was implemented backward-compatibly; existing calls to
  [`commons()`](https://posit-dev.github.io/commons/r/dev/reference/commons.md)
  will raise a deprecation warning with migration instructions.

- [`agent()`](https://posit-dev.github.io/commons/r/dev/reference/agent.md)
  (formerly
  [`commons()`](https://posit-dev.github.io/commons/r/dev/reference/commons.md))
  gains a `mode` argument. With `mode = "trusted only"`, the agent
  answers only with trusted calculations. It never writes its own SQL or
  R, and it tells the user when no trusted calculation answers a
  question. These answers carry no provenance markers.

- `describe_table` reports complete table schemas and documentation
  without a sampled-row summary. DuckDB descriptions use database-native
  types. Snowflake and Databricks continue to use native metadata, while
  other DBI connections infer R column classes from five sampled rows,
  or zero rows in trusted-only mode
  ([\#319](https://github.com/posit-dev/commons/issues/319)).

- [`trajectory_read()`](https://posit-dev.github.io/commons/r/dev/reference/trajectory_read.md)
  now returns a `user` field with the originating Shiny session username
  supplied by Connect. With `log = TRUE`, authenticated session users
  are recorded with conversation trajectories; older logs and anonymous
  sessions return `NA_character_`
  ([\#316](https://github.com/posit-dev/commons/issues/316)).

- On macOS, R code run by `run_r` can now start other programs, such as
  through [`system()`](https://rdrr.io/r/base/system.html) or
  [`system2()`](https://rdrr.io/r/base/system2.html). The sandbox
  previously stopped every program it started. Those programs run under
  the same sandbox as the R session.

- R code run by `run_r` can no longer send a signal to the application
  process’s ID or to its process group. On Linux, the programs it starts
  can also no longer leave its process group, so they all stop when the
  R session ends.

- The CSS classes on `run_r`’s display are now `commons-run-display`,
  `commons-run-details`, `commons-run-code`, and `commons-run-plot`,
  without the `-r`, because the Python package’s code tool uses the same
  classes. App CSS that targets the old `commons-run-r-*` names needs
  updating.

## commons 0.1.1

CRAN release: 2026-10-07

- Fixes an issue with the R code sandbox where the generated policy
  would be too long when there were thousands of R packages installed.

- A number of improvements to documentation.

## commons 0.1.0

CRAN release: 2026-09-11

- Initial release.
