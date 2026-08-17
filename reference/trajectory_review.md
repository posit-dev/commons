# Review commons trajectories

`trajectory_review()` launches a Shiny app for browsing conversation
trajectories read with
[`trajectory_read()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/trajectory_read.md).
The app charts each trust level's share of answers over time—binned by
day, week, or month, using the finest unit the volume of answers
supports—alongside a list of conversations or of individual questions,
filterable by date and trust level. The transcript reconstructs each
answer's recorded Commons presentation: accepted citations appear inline
at their original locations, A/C provenance appears after the answer,
and rejected citation attempts appear in a separate "Review audit"
aside.

Transcripts are reviewable rather than live: conversations and questions
can be flagged for review and annotated with notes. Notes apply to the
whole conversation, or to a single question-and-answer exchange selected
in the transcript. Flags and notes land in `review_file`, one JSON
record per line, and are restored when the viewer reopens.

New review records use schema version 1 and include a unique event id,
UTC timestamp, reviewer username, trajectory source, conversation id,
optional exchange number, action, and optional note. Exchange-level
records also snapshot the question and trust tag.

Each answer's trust tag and citation outcomes are read back exactly as
[`trajectory_read()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/trajectory_read.md)
recorded them. The viewer uses those decisions to reconstruct Commons
citation asides from the raw ellmer answer; it never re-verifies
citations against a corpus. Missing or conflicting records are omitted
rather than inferred.

Logged calls that aren't part of the agent's question-and-answer record—
shinychat's conversation-title generation, and completions with no user
turn—are excluded from the viewer.

## Usage

``` r
trajectory_review(
  trajectories = trajectory_read(),
  review_file = Sys.getenv("COMMONS_REVIEW_FILE", unset = "commons-review.jsonl")
)
```

## Arguments

- trajectories:

  A named list of conversations, as returned by
  [`trajectory_read()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/trajectory_read.md).

- review_file:

  Path of the JSONL file that review actions append to: flags, unflags,
  and feedback notes, each with a timestamp, the conversation id, and
  (for questions) the exchange number. Created on first use; flags and
  notes recorded here are restored when the viewer reopens. Defaults to
  `COMMONS_REVIEW_FILE` when set.

## Value

A [`shiny::shinyApp()`](https://rdrr.io/pkg/shiny/man/shinyApp.html)
object. Calling `trajectory_review()` at the console launches the
reviewer; the result can also be served as the last expression of an
`app.R`.

## Details

A single reviewer app writes all of its review events to `review_file`.
For a deployed app, point `COMMONS_REVIEW_FILE` at persistent storage:
files in a Posit Connect app's working directory are replaced on
redeployment. File-backed review apps should use one Connect process
because separate processes do not coordinate file writes or in-memory
review state.

## Examples

``` r
if (FALSE) { # \dontrun{
trajectory_review()

trajectory_review(trajectory_read(from = "2026-07-01"))
} # }
```
