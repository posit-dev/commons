# commons <a href="https://posit-dev.github.io/commons/"><img src="pkg-r/man/figures/logo.png" align="right" height="240" alt="The package's hex sticker; a Common Kingfisher drawn in a cartoonish style, sitting on a park bench with a plaque reading 'commons'. Behind the bird is an open green space." /></a>

> Both packages are highly experimental; expect their interfaces to change rapidly.

commons helps data scientists build trustworthy data agents. It provides a meta-harness; you bring your data and understanding of how to do calculations on it, and the package situates that in a set of prompts and tools that make for a more accurate, fast, and cost-effective agent than a regular coding agent provided with the same information.

commons agents use a pool of trusted calculations drawn from your existing work, like Shiny apps and Quarto docs, to answer questions. (You can also import existing trusted calculations from semantic layers in Snowflake and Databricks.) When the question can't be answered by a trusted calculation, the agent can search across context you've compiled to query data directly, and the response will be deterministically tagged as untrusted.

<img src="https://github.com/user-attachments/assets/67dcf1f2-1496-406a-96cb-50a2e7050eeb" alt="A screencast demonstrating a commons data agent answering questions with a trusted calculation and then a direct data query. In the first case, there's a provenance pill that marks the answer as verified. In the second case, the pill reads 'Untrusted.'" width="100%" />

commons agents support a wide variety of LLM providers via [ellmer](https://ellmer.tidyverse.org/). Extracted context is stored in plain-text [data-dict.yaml](https://data-dict.tidyverse.org/) and `.R` files.

## Two languages, one design

This repository holds both implementations of commons. Today only the R package works; the Python port is being built to the same design, with the same three layers (data, semantic, and context), the same tools, and the same provenance semantics, so that an agent will eventually behave the same way whichever language you build it in.

### R

The R package is the original and the one to reach for today. It is usable and in internal use, though still experimental.

``` r
# install.packages("pak")
pak::pak("posit-dev/commons/pkg-r")
```

To learn more, see `vignette("commons", package = "commons")`, the [reference site](https://posit-dev.github.io/commons/), or [`pkg-r/README.md`](pkg-r/README.md).

### Python

The Python package is early work and not yet usable. It will use [chatlas](https://posit-dev.github.io/chatlas/) for provider support, and will be published to PyPI as `posit-commons` while importing as `commons`:

``` python
from commons import Commons
```

Nothing is published yet, so there is no install command to give you. Follow along in [`pkg-py/README.md`](pkg-py/README.md).

## Contributing

Each package builds and tests from its own directory, `pkg-r/` for R and `pkg-py/` for Python, rather than from the repository root.

If you worked in this repository before the two packages were split apart, [`MIGRATING.md`](MIGRATING.md) covers what moved and what to change in your setup.
