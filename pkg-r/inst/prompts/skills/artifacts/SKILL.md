---
name: artifacts
description: How to make something the user can keep or share on its own, apart from the chat, from a single plot or table to a full report. Load it before you create or edit one.
metadata:
  topic: documents
  requires: edit_artifact
---

When the user asks for something they will read on its own, keep, or share, such as a plot, a table, or a report, write it as a Quarto document. It opens in a panel beside the chat as you write it: each R cell runs as soon as you finish writing it, and the user sees the knitted result rather than source. Answer ordinary questions in the chat.

Start the document on its own line with `<artifact id="sales-by-region" title="Sales by region">` and end it with `</artifact>`. Between them goes the full `.qmd` source: Markdown and R code cells, optionally after YAML frontmatter. The id is a short lowercase slug. Writing the tag again with the same id replaces that document; a new id makes a new one. In the chat, the document is replaced by a link to it, so don't repeat its contents in your reply.

The tag's title is the document's title. Frontmatter can override it and set `subtitle` or `date`; the format, theme, and execution options are set for you.

Write as much prose as the user seems to want, which may be none: a request for a plot or table may want only that. Users share documents on their own, so make each one presentable without the chat.

Documents can't reach your R session or earlier tool results. Get data in a cell through the `commons` object, whose methods take the same arguments as the matching tools:

```r
revenue <- commons$metrics(metrics = "net_revenue", dimensions = "region")
```

- `commons$measure(name, arguments)`, as for `call_measure`.
- `commons$metrics(metrics, dimensions, filters, where, arguments, source)`, as for `call_metrics`.
- `commons$calculation(name, arguments, source)`, as for `call_calculation`.
- `commons$run_sql(query, source)`, as for `run_sql`. Prefer the trusted calculations above; use SQL only for what they don't cover.

Each call returns a data frame, or a vector for a measure that returns a value. Only use the methods for a tool you have.

- Run the calculations with tools first, so you know what they return before you write about them.
- Every number in the document must come from a `commons` call or a cell that runs when it renders. Write key figures in prose as inline R expressions, such as `` `r nrow(revenue)` ``, rather than typing them.
- Cells run in order in a fresh R session without network access, using installed packages. Keep them short. Readers see code folded beneath each result, so don't set `echo` or other options that hide code.
- The document is shown as knitted Markdown. Use headings, paragraphs, lists, tables, R cells with static plots, and `::: {.callout-note}` callouts; tabsets, cross-references, and interactive widgets aren't supported.

Create a document only by writing the tag; `edit_artifact` works only on a document you have already written. Change a document with `edit_artifact` rather than writing it again. Its result says whether the new version rendered; if it didn't, fix the error before telling the user the document is ready. If a document you wrote with the tag fails to render, you'll be told on the next turn.
