
<!-- README.md is generated from README.Rmd. Please edit that file -->

# commons

<!-- badges: start -->

[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
[![CRAN
status](https://www.r-pkg.org/badges/version/commons)](https://CRAN.R-project.org/package=commons)
<!-- badges: end -->

commons allows you to build correct and easy-to-use self-service data
science agents for your organization. For data scientists, commons
agents are joyful to build, customize, and maintain, and are designed to
be deployed. For end users, commons agents are a joy to use.

$$gif$$

commons agents support whatever LLMs your organization has deployed
already.

To get started, configure a database connection with `data_source()` and
then two layers on top of it:

- Assemble a `semantic_layer()`, a pool of pre-vetted queries that
  directly use the definitions defined by your data science team. This
  can make use of existing semantic layers defined with other
  technologies, or can be assembled using existing, trusted data
  artifacts (like dashboards and parameterized reports). The semantic
  layer is the agents’ happy path, relying on existing, trusted
  definitions.
- Assemble a `context_layer()`, a pool of free-text knowledge that the
  agent can search through when a data query is not covered by the
  semantic layer. This layer informs how the agent will author fallback
  SQL queries.

### Defining measures

A semantic layer is built from **measures**: governed calculations that
the agent can call by name. You can write each measure with `measure()`,
or – often more naturally – define them as ordinary documented R
functions and load them with `read_measures()`.

A function becomes a measure when its roxygen2 block is marked with
`#' @measure` – much like `@export` marks a function as part of a
package’s public interface. Other documented functions in the file are
ignored, so helpers can live alongside your measures. The measure’s
name, description, and arguments are read directly from the
documentation:

``` r
#' Count orders
#'
#' @description Total orders, optionally filtered by region and period.
#'
#' @param region `string` The sales region. Omit for all regions.
#' @param period `enum[day, week, month]` Aggregation period.
#' @param top_n `integer` Maximum number of rows to return.
#'
#' @return An integer count of orders.
#' @measure
order_count <- function(region = NULL, period, top_n = 10L) {
  # ... ordinary R that computes the measure ...
}
```

The argument type is declared with a leading code span in each `@param`:
`string`, `integer`, `number`, `boolean`, `enum[...]` for a fixed set of
values, or `type[]` for an array (e.g. `string[]`). An argument is
required when it has no default in the function signature; otherwise it
is optional. Untyped arguments fall back to a type inferred from their
default.

A measure can call helper functions defined in the same file – or in
sibling files passed together in a single `read_measures()` call –
because all files loaded in one call are sourced into a shared
environment.

Pass the script – or a directory of scripts – straight to
`semantic_layer()`, alongside any inline `measure()` definitions:

``` r
semantic_layer("measures.R")
```

Paths are read with `read_measures()`, which you can also call directly
when you want the list of measures on its own.

With those two pieces, you’ve got the necessary pieces to ship on Posit
Connect, in Slack/Teams, or via an email inbox. In production, the agent
will search the context layer to determine the correct queries to answer
user questions (or decline to answer). If you want, commons can log
interactions, run live evals, collect metrics (like Thumbs up/down), and
integrate with your existing data request intake flows.

After this initial proof-of-concept, you’ll want to evaluate the agent.
Your existing data artifacts provide a source of known-correct analysis
flows; with these sources, commons provides a skill to create a set of
**offline evals** that allow you to benchmark your agent’s correctness.
With these evals in place, you can:

- Test how well various models do, optimizing for cost, correctness, and
  latency.
- Improve the agent itself. Use commons’ Critique Mode to try out test
  queries (or see what users have asked in production) and provide
  feedback on the responses, automatically updating the context layer in
  the process.

commons also supports **online validation**, where either monitoring of
production traffic for corrective language or follow-up adversarial
review across all traffic can surface questionable answers to you in
Critique Mode.
