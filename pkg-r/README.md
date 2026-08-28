
<!-- README.md is generated from README.Rmd. Please edit that file -->

# commons <a href="https://posit-dev.github.io/commons/"><img src="man/figures/logo.png" align="right" height="240" alt="The package's hex sticker; a Common Kingfisher drawn in a cartoonish style, sitting on a park bench with a plaque reading 'commons'. Behind the bird is an open green space." /></a>

<!-- badges: start -->

[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
<!-- badges: end -->

> This package is highly experimental.

commons helps data scientists build trustworthy data agents.

Data teams typically have trusted code that they use to analyze their
data and build reports and apps. commons leverages their expertise,
situating that information in a series of prompts and tools designed to
create an accurate, fast, and cost-effective agent.

Trusted calculations can come from R code (as *measures*), [data
dictionary](https://data-dict.tidyverse.org/) definitions, Snowflake
semantic views, or Databricks metric views.

<img src="https://github.com/user-attachments/assets/67dcf1f2-1496-406a-96cb-50a2e7050eeb" alt="A screencast demonstrating a commons data agent answering questions with a trusted calculation and then a direct data query. In the first case, a provenance marker reads 'Verified answer', while in the second it reads 'Untrusted'." width="100%" />

## Installation

To install the package, run:

``` r
# install.packages("pak")
pak::pak("posit-dev/commons/pkg-r")
```

## Get started

commons uses [ellmer](https://ellmer.tidyverse.org/) to access LLMs, so
you will need access to one of ellmer’s supported providers.

We recommend building commons agents with the help of the [agent
skill](https://agentskills.io/) that ships with the package. The skill
helps coding agents build, evaluate, and improve commons agents.

To make the skill available to Posit Assistant or Codex, copy the skill
and its references to `.agents/skills`:

``` r
skill <- system.file("skills", "commons", package = "commons")
dir.create(".agents/skills", recursive = TRUE, showWarnings = FALSE)
file.copy(skill, ".agents/skills", recursive = TRUE)
```

For Claude Code, copy the skill and its references to `.claude/skills`:

``` r
skill <- system.file("skills", "commons", package = "commons")
dir.create(".claude/skills", recursive = TRUE, showWarnings = FALSE)
file.copy(skill, ".claude/skills", recursive = TRUE)
```

The [Introduction to
commons](https://posit-dev.github.io/commons/articles/commons.html)
vignette also explains the structure of a commons agent and the creation
process.

## Trusted answers

There are two provenance paths available to a commons agent: when users
ask questions for which there is trusted code, the agent follows the
“happy path,” running that code and reporting the result. If the user
asks a question for which trusted code is not available, the agent
writes custom R or SQL code, leaning on additional context provided to
the agent.

Answers display provenance according to the analysis path followed, so
users can determine how much trust to put in a given answer.

For more information, see the [Introduction to
commons](https://posit-dev.github.io/commons/articles/commons.html)
vignette.

<!-- Diagram source: Introduction to commons vignette. Update it there, then save the image. https://github.com/posit-dev/commons/blob/a29ac09c39c8edb99f2a9ea0ecc1836e6538bb25/vignettes/commons.Rmd#L76 -->

<img src="man/figures/README-trust-flow.png" alt="Flow diagram. A question first searches trusted calculations. The high-trust path runs a relevant trusted calculation and ends with a green check-shield marker for the Verified answer outcome. The lower-trust path searches context and writes custom SQL or R, ending with either a blue quote-mark citation marker for the Cited outcome or a yellow exclamation marker for the Untrusted outcome." width="684" />

## Evaluation

The [DevRel agent](https://github.com/posit-dev/devrel-agent) is an
example commons agent that answers questions about adoption, engagement,
and growth across Posit’s open-source projects. The DevRel agent
repository contains an
[evaluation](https://github.com/posit-dev/devrel-agent/tree/main/evals)
that compares performance between the commons agent and Claude Code.
Both have access to the same underlying data.

In this evaluation, the commons agent had higher mean accuracy (86.3%
vs. 83.5%), took less time to answer questions (a median of 31.0
vs. 60.5 seconds), and used fewer output tokens (243,403 vs. 439,188
total).

<img src="man/figures/README-eval-plot-1.png" alt="Three bar charts compare commons with Claude Code. commons has higher mean accuracy, lower median solver time, and fewer total output tokens." width="100%" />

In the evaluation, both harnesses use Claude Sonnet 5 at medium effort.
The evaluation runs each of 32 questions three times. Questions require
either a numeric answer, a table, a nuanced response, or recognition
that the available data cannot answer them.
