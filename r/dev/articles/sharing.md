# Sharing a commons across projects

Suppose you’ve collected your team’s trusted calculations in a commons.
You want an agent to use them, but you also need those same calculations
in Quarto reports, Shiny apps, or scheduled workflows. When you change a
calculation, you don’t want to update a copy in every project.

You can put the code that builds [the
commons](https://posit-dev.github.io/commons/r/dev/reference/commons.md)
in an R package, then call it from each project.

## Put it in a package

Let’s call the package surveys. In `inst/measures/biodiversity.R`,
define a measure that totals survey counts by site:

``` r

#' Individuals observed by site
#'
#' Counts recorded during surveys, not a complete population census.
#' @measure
individuals_by_site <- function(survey_db) {
  DBI::dbGetQuery(
    survey_db,
    "SELECT site, SUM(count) AS individuals FROM observations GROUP BY site ORDER BY site"
  )
}
```

The `@measure` annotation marks the function as a trusted calculation.
Keeping the file under `inst/` lets commons read its source and
annotations after installation. (If you prefer to define the function in
`R/`, use
[`measure()`](https://posit-dev.github.io/commons/r/dev/reference/measure.md)
instead of the roxygen2-style annotation.)

In `R/biodiversity_commons.R`, export a function that builds the
commons:

``` r

#' Create the survey commons
#' @param observations A data frame with site and count columns.
#' @return A commons object.
#' @export
biodiversity_commons <- function(observations) {
  commons::commons(
    data_sources = list(
      survey_db = commons::data_source(observations = observations)
    ),
    semantic_layer = commons::semantic_layer(
      system.file("measures", package = "surveys", mustWork = TRUE)
    )
  )
}
```

Add commons and DBI to `Imports` in `DESCRIPTION`, then run
`devtools::document()` and install the package. [R
Packages](https://r-pkgs.org/whole-game.html) walks through these steps
if they’re new to you.

You can now build the commons and call the measure yourself:

``` r

observations <- data.frame(
  site = c("Oak Bluff", "Oak Bluff", "Pine Ridge"),
  count = c(12, 8, 5)
)

biodiversity <- surveys::biodiversity_commons(observations)
biodiversity$measure("individuals_by_site")
```

``` text
        site individuals
1  Oak Bluff          20
2 Pine Ridge           5
```

This returns a data frame without calling a model. You can also call
metrics (from data-dict.yaml `definitions`) with `$metrics()` and exact
trusted queries (if you use Snowflake/Databricks) with `$calculation()`.

## Use the commons across projects

A Quarto report can now read survey data and call the trusted
calculation directly:

```` markdown
---
title: "Survey counts"
format: html
---

```{r}
observations <- read.csv("observations.csv")
biodiversity <- surveys::biodiversity_commons(observations)
biodiversity$measure("individuals_by_site")
```
````

To build an agent, pass the commons to
[`agent()`](https://posit-dev.github.io/commons/r/dev/reference/agent.md):

``` r

biodiversity <- surveys::biodiversity_commons(observations)
agent <- commons::agent(
  client = ellmer::chat("anthropic/claude-sonnet-5"),
  commons = biodiversity
)
```

When the same commons is used across projects, those various projects
will use whatever trusted code is contained in the commons. So, after
updating the package in a consuming project, the next report render or
app restart uses the revised code.
