# Getting started with commons

Not much to see here yet. We’ll be back!

This vignette shows the shape of a small commons project.

``` r

library(commons)
```

## Setting up the project directory

A commons agent is easiest to maintain when the pieces live in separate
files:

``` text
.
|-- R/
|   |-- data_sources.R
|   |-- semantic_layer.R
|   `-- context_layer.R
|-- app.R
|-- system-prompt.md
`-- context/
    `-- metrics.md
```

The bundled `commons` agent skill can also be copied into your project.
The skill helps coding agents follow best practices when building and
iterating on commons agents.

``` r

dir.create(".agents/skills", recursive = TRUE, showWarnings = FALSE)
file.copy(
  system.file("skills", "commons", package = "commons"),
  ".agents/skills",
  recursive = TRUE
)
```

For Claude Code, copy the same directory into `.claude/skills` instead.
