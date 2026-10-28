# Gather trusted calculations and context

`commons()` gathers a team's data sources, semantic layer, and context
layer into one object, "the commons", that code can call directly
without a model. Pass it to
[`agent()`](https://posit-dev.github.io/commons/r/dev/reference/agent.md)
to build an agent in R, or place it in an R session that a coding agent
already controls.

## Usage

``` r
commons(..., data_sources, semantic_layer = NULL, context_layer = NULL)
```

## Arguments

- ...:

  These dots are for future extensions and must be empty.

- data_sources:

  A
  [`data_source()`](https://posit-dev.github.io/commons/r/dev/reference/data_source.md),
  or a named list of them. Measures can take a source's connection as an
  argument named after the source; see
  [`semantic_layer()`](https://posit-dev.github.io/commons/r/dev/reference/semantic_layer.md).

- semantic_layer:

  An optional
  [`semantic_layer()`](https://posit-dev.github.io/commons/r/dev/reference/semantic_layer.md).

- context_layer:

  An optional
  [`context_layer()`](https://posit-dev.github.io/commons/r/dev/reference/context_layer.md).

## Value

A `commons` object with methods:

- `$search(query)` searches trusted calculations.

- `$measure(name, arguments)` runs a measure.

- `$metrics(metrics, dimensions, filters, where, arguments, source)`
  computes governed metrics. `where` takes simple conditions on
  documented columns, either as a string like
  `"project = 'dplyr' AND date >= '2026-06-01'"` or as a list of
  `c(column, op, value)` triples.

- `$calculation(name, arguments, source)` runs an exact trusted query.

- `$context(query)` searches trusted context.

- `$describe(table, source)` describes a table.

- `$run_sql(query, source)` runs a read-only query and returns a data
  frame. Governed definitions can be written as `{{name}}` tokens (or
  `{{table::name}}` when qualification is needed), and each expands to
  its compiled SQL before the query runs.

## Details

All arguments must be named.

## Using commons with other coding agents

`commons()` is the entry point to use commons with external coding
agents. The approach depends on whether the coding agent already has a
persistent R session. For example, Posit Assistant connects to the
user's R session. Claude Code and Codex, by contrast, do not have a
built-in connection to a persistent R REPL.

**For agents that already have an R session, like Posit Assistant**,
create a `commons()` object in the relevant `.Rprofile` and then add a
line telling the agent to print it out before doing data analysis:

    The R session has an object called `commons` that holds this team's trusted
    code and context. Before analyzing data, run `print(commons)`, and use its
    calculations where they apply in favor of writing analysis code ad-hoc.

**Claude Code and Codex have no persistent R session of their own.**
They can get one through [MCP
Console](https://posit-dev.github.io/mcp-console/). Its R session reads
the project's `.Rprofile` like any other, so build `commons` there in
the same way, and then edit the console tool's description to tell the
model to print out `commons` before analyzing data.

To use MCP console, register it for the project, from the project
directory:

    uvx mcp-console configure-client claude --directory .
    uvx mcp-console configure-client codex --directory .

Then configure MCP Console to offer the model only R, so that it queries
data through `commons$run_sql()` rather than sending SQL to a database
itself, and to mention `commons` in its tool description. A configured
description replaces the one MCP Console generates, so start from an
export of the resolved configuration:

    mkdir -p .agents/console
    uvx mcp-console config resolve --full --no-project-config \
      -c 'languages=[r]' > .agents/console/config.yaml

In that file, keep `languages: [r]`, and add the same sentence to the
end of the exported description:

    languages:
      - r
    tool:
      description: |-
        # ...the exported description, unchanged...

        The R session has an object called `commons` that holds this team's
        trusted code and context. Before analyzing data, run
        `print(commons)`, and use its calculations where they apply in favor of
        writing analysis code ad-hoc.

Claude Code shows the tool description only once the agent loads the
tool, so add the sentence to the end of `tool.instructions` as well.

`$context()` needs one more step for now. This applies even without a
context layer when a data source has a data dictionary or semantic
model, since `$context()` searches those too. It relies on DuckDB's
`fts` extension, which MCP Console's sandbox can't download. MCP Console
can install the extension itself, but only into its own cache, which R's
duckdb doesn't read by default. Point R at that cache with an absolute
path (`~` and environment variables aren't expanded):

    environment:
      # macOS; on Linux, /home/you/.cache/mcp-console/dependencies/duckdb
      DUCKDB_R_HOME: /Users/you/Library/Caches/mcp-console/dependencies/duckdb

Then add one more sentence to both `tool.description` and
`tool.instructions`, so the agent asks MCP Console to install the
extension:

    The first time you run `commons$context()`, include
    `"requirements": {"duckdb": ["fts"]}` in the same call.

In either setup, `$run_sql()` refuses queries that write, but that check
isn't a security boundary. Code that the agent runs in the same R
session can reach anything the session can, including the connections
behind `commons`. Connect to databases with a read-only role.

## Lifecycle

Before commons 0.2.0, `commons()` built the agent itself, taking
`client` as its first argument. Calls in that form still work, with a
deprecation warning, and return an agent as before. Use
[`agent()`](https://posit-dev.github.io/commons/r/dev/reference/agent.md)
instead.

## Examples

``` r
if (FALSE) { # \dontrun{
commons <- commons(
  data_sources = data_source(warehouse = con),
  semantic_layer = sem,
  context_layer = context_layer(files = "notes.md")
)
commons
commons$search("revenue by region")
commons$measure("revenue_by_region", arguments = list(region = "West"))

# The same object backs an agent:
agent <- agent(ellmer::chat_anthropic(), commons = commons)
} # }
```
