# Changelog

## commons (development version)

- [`commons()`](https://posit-dev.github.io/commons/r/dev/reference/commons.md)
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
