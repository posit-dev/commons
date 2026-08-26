# Review commons trajectories

`trajectory_review()` launches a Shiny app for browsing and annotating
conversation trajectories read with
[`trajectory_read()`](https://posit-dev.github.io/commons/reference/trajectory_read.md).
Reviewers can filter questions by date and trust level, inspect complete
conversations, flag conversations or individual question-and-answer
exchanges, and record notes.

Use the reviewer to assess answer quality, track provenance outcomes
over time, record feedback to guide agent improvements, and identify
conversations for further review.

## Usage

``` r
trajectory_review(trajectories = trajectory_read(), review_dir = NULL)
```

## Arguments

- trajectories:

  A named list of conversations, as returned by
  [`trajectory_read()`](https://posit-dev.github.io/commons/reference/trajectory_read.md).

- review_dir:

  Optional directory where review actions write generated Markdown
  documents. Defaults to `COMMONS_REVIEW_DIR` when set and otherwise to
  `commons-reviews` in the working directory.

## Value

A [`shiny::shinyApp()`](https://rdrr.io/pkg/shiny/man/shinyApp.html)
object. Calling `trajectory_review()` at the console launches the
reviewer; the result can also be served as the last expression of an
`app.R`.

## Details

A single reviewer app writes all review documents to `review_dir`. Pass
it directly, set `COMMONS_REVIEW_DIR` for the current R process with
[`Sys.setenv()`](https://rdrr.io/r/base/Sys.setenv.html), or add it to
`.Renviron` to keep the setting across local R sessions. Without either,
reviews land in `commons-reviews` relative to the app's working
directory.

On Posit Connect, opening a new browser session does not reset review
files. By default, review documents are written to the app's working
directory, where they are replaced on redeployment. Set `review_dir` to
persistent storage when reviews must survive redeployment. Review apps
should use one Connect process because separate processes do not
coordinate file writes or in-memory review state.

All sessions of one reviewer app share the same flags and notes; review
state is not separated by user. Notes record `session$user`, the login
information supplied by the Shiny host, or `"unknown"` when it is
unavailable. Flags do not record who changed them.

## Viewer

The app charts each trust level's share of answers over time. It uses
the finest daily, weekly, or monthly grouping that averages at least
five answers per displayed bin, or the coarsest available grouping if
none does. Weekly and monthly groupings require windows of at least 14
and 60 days, respectively. A question list is grouped by conversation
and can be filtered by date and trust level.

## Review records

Notes can apply to a whole conversation or to one question-and-answer
exchange selected in the transcript. Flags and notes are stored as one
generated Markdown document per reviewed conversation and are restored
when the viewer reopens.

Each document contains the complete reviewer-visible conversation and
its tool activity. YAML frontmatter stores active flags and note history
so the reviewer can restore its state and agents can identify flagged
conversations, exchanges, and reviewer notes. The Markdown body is the
human-readable transcript for joint human-agent review.

## Transcript contents

The transcript uses the same commons and shinychat renderer as live
conversations, preserving recorded messages and tool activity.
Provenance markers are reconstructed from recorded provenance tags, but
inline citations are not recreated. Generated review documents list the
recorded citation decisions separately.

Search-pool results are omitted because later tool calls record any
selected measure; other tool results are limited to 50 lines or 20,000
characters.

Trust filters use each answer's provenance tag exactly as
[`trajectory_read()`](https://posit-dev.github.io/commons/reference/trajectory_read.md)
recorded it. Missing or conflicting records are omitted rather than
inferred.

Logged calls that aren't part of the agent's question-and-answer record
are excluded from the viewer. These include shinychat's
conversation-title generation and completions with no user turn.

## Examples

``` r
if (FALSE) { # \dontrun{
trajectory_review()

trajectory_review(trajectory_read(from = "2026-07-01"))

Sys.setenv(COMMONS_REVIEW_DIR = "/path/to/persistent/reviews")
trajectory_review()
} # }
```
