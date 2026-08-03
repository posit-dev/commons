# commons

> This package is highly experimental; expect its interface to change
> rapidly.

commons allows data scientists to build self-service data agents for
their organization.

commons agents use a pool of trusted calculations drawn from your
existing work, like Shiny apps and Quarto docs, to answer questions.
(You can also import existing trusted calculations from semantic layers
in Snowflake and Databricks.) When the question can’t be answered by a
trusted calculation, the agent can search across context you’ve compiled
to query data directly, and the response will be deterministically
tagged as untrusted.

![A screencast demonstrating a commons data agent answering questions
with a trusted calculation and then a direct data query. In the first
case, there's a provenance pill that marks the answer as verified. In
the second case, the pill reads
'Untrusted.'](https://github.com/user-attachments/assets/67dcf1f2-1496-406a-96cb-50a2e7050eeb)

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

To learn more, see
[`vignette("commons", package = "commons")`](https://solid-adventure-ny1mpqy.pages.github.io/articles/commons.md).
