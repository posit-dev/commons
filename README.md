
<!-- README.md is generated from README.Rmd. Please edit that file -->

# commons <a href="https://posit-dev.github.io/commons/"><img src="man/figures/logo.png" align="right" height="240" alt="The package's hex sticker; a Common Kingfisher drawn in a cartoonish style, sitting on a park bench with a plaque reading 'commons'. Behind the bird is an open green space." /></a>

<!-- badges: start -->

[![Lifecycle:
experimental](https://img.shields.io/badge/lifecycle-experimental-orange.svg)](https://lifecycle.r-lib.org/articles/stages.html#experimental)
<!-- badges: end -->

> This package is highly experimental; expect its interface to change
> rapidly.

commons helps data scientists build trustworthy data agents. It provides
a meta-harness; you bring your data and understanding of how to do
calculations on it, and the package situates that in a set of prompts and
tools that make for a more accurate, fast, and cost-effective agent than
a regular coding agent provided with the same information.

commons agents use a pool of trusted calculations drawn from your
existing work, like Shiny apps and Quarto docs, to answer questions.
(You can also import existing trusted calculations from semantic layers
in Snowflake and Databricks.) When the question can’t be answered by a
trusted calculation, the agent can search across context you’ve compiled
to query data directly, and the response will be deterministically
tagged as untrusted.

<img src="https://github.com/user-attachments/assets/67dcf1f2-1496-406a-96cb-50a2e7050eeb" alt="A screencast demonstrating a commons data agent answering questions with a trusted calculation and then a direct data query. In the first case, there's a provenance pill that marks the answer as verified. In the second case, the pill reads 'Untrusted.'" width="100%" />

commons agents support a wide variety of LLM providers via
[ellmer](https://ellmer.tidyverse.org/). Extracted context is stored in
plain-text [data-dict.yaml](https://data-dict.tidyverse.org/) and `.R`
files.

## Installation

To install the package, run:

``` r
# install.packages("pak")
pak::pak("posit-dev/commons")
```

To learn more, see `vignette("commons", package = "commons")`.
