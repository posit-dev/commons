---
name: artifacts
description: How to write a report or another document the user will read on its own, keep, or share. Load it before you create or edit a document.
metadata:
  topic: documents
  requires: edit_artifact
---

When the user asks for a report or another document they will read on its own, keep, or share, write it as a Quarto document. It opens in a panel beside the chat as you write it: each R cell runs as soon as you finish writing it, and the user sees the knitted result rather than source. Answer ordinary questions in the chat.

Start the document on its own line with `<artifact id="sales-by-region" title="Sales by region">` and end it with `</artifact>`. Between them goes the full `.qmd` source: YAML frontmatter, then Markdown and R code cells. The id is a short lowercase slug. Writing the tag again with the same id replaces that document; a new id makes a new one. In the chat, the document is replaced by a link to it, so don't repeat its contents in your reply.

In the frontmatter, set `title` and, if useful, `subtitle` or `date`; the format, theme, and execution options are set for you.

Documents can't reach your data sources, your R session, or earlier tool results. Get data in a cell by calling a trusted calculation through the `trusted` object, with the same arguments as its tool:

```r
revenue <- trusted$metrics(metrics = "net_revenue", dimensions = "region")
```

Each trusted-calculation tool you have has a counterpart:

- `trusted$measure(name, arguments)`, as for `call_measure`.
- `trusted$metrics(metrics, dimensions, filters, where, arguments, source)`, as for `call_metrics`.
- `trusted$calculation(name, arguments, source)`, as for `call_calculation`.

Write arguments out as literals: strings, numbers, and `c()` or `list()` of them, not variables or computed values. Each call returns a data frame, or a vector for a measure that returns a value. Before the cell runs, each call is run, its result is saved with the document, and the call is replaced with a read of the saved file.

- Run the calculations with tools first, so you know what they return before you write about them.
- Every number in the document must come from a trusted call or a cell that runs when it renders. Write key figures in prose as inline R expressions, such as `` `r nrow(revenue)` ``, rather than typing them.
- Cells run in order in a fresh R session without network access, using installed packages. Keep them short; readers see code folded.
- The document is shown as knitted Markdown. Use headings, paragraphs, lists, tables, R cells with static plots, and `::: {.callout-note}` callouts; tabsets, cross-references, and interactive widgets aren't supported.

Create a document only by writing the tag; `edit_artifact` works only on a document you have already written. Change a document with `edit_artifact` rather than writing it again. Its result says whether the new version rendered; if it didn't, fix the error before telling the user the document is ready. If a document you wrote with the tag fails to render, you'll be told on the next turn.
