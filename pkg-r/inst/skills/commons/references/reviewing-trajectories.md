# Review trajectories visually and interactively

Use this reference when the user wants to review conversations themselves, plot trust levels over time, or browse traces visually and interactively. Build a small review tool in the user's project, tailored to the question.

## Read the evidence

Reuse loaded trajectories or start with a bounded read:

```r
trajectories <- commons::trajectory_read(n = 100, from = Sys.Date() - 30)
```

See `?commons::trajectory_read` for trace sources and access requirements.

Read exchange-level provenance from `attr(turns, "provenance")`, which contains `provenance_tag` and `citation_decisions`. Count actual user questions, excluding tool-result turns, internal follow-ups, and conversation-title calls. Preserve conversation IDs and exchange numbers for drill-down.

Map recorded provenance tags A/B/C to the outcomes **Trusted / Cited / Untrusted**. Keep absent or conflicting tags as **Unclassified**, not Untrusted or proof that no data tool ran. These outcomes describe provenance, not answer correctness; do not reclassify them from the answer's wording.

## Plot trust over time

Prefer an interactive 100% stacked area chart of daily or weekly outcome shares, including Unclassified. Put counts and denominators in hover details, not labels on every segment. Widen sparse bins and distinguish missing data from zero counts.

`last_active` is a conversation timestamp, not each answer's time. If using it, label the chart as exchanges grouped by conversation last activity; do not invent exchange timestamps. True answer-time trends require the corresponding raw span timestamps. State the read window and any `n` limit: recent conversations are not a representative sample of all usage.

## Build the smallest useful reviewer

Prefer self-contained HTML with a question list and a selected transcript showing tool activity and citation decisions, as well as any other features requested by the user. Keep exchanges identifiable and long results expandable.

Make it as simple as possible unless otherwise requested. Do not add unnecessary styling, filters, buttons, etc.

The purpose is to make a tool for the user that makes it easy for them to look through the trajectories.
