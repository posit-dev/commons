# Review commons trajectories

`trajectory_review()` launches a Shiny app for browsing conversation
trajectories read with
[`trajectory_read()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/trajectory_read.md).
The app charts each trust level's share of answers over time—binned by
day, week, or month, using the finest unit the volume of answers
supports—alongside a list of conversations or of individual questions,
filterable by date and trust level, and a transcript of each with the
provenance pills the commons chat UI would show.

Transcripts are reviewable rather than live: conversations and questions
can be flagged for review and annotated with notes. Notes apply to the
whole conversation, or to a single question-and-answer exchange selected
in the transcript. Flags and notes land in `review_file`, one JSON
record per line, and are restored when the viewer reopens.

New review records use schema version 1 and include a unique event id,
UTC timestamp, reviewer username, trajectory source, conversation id,
optional exchange number, action, and optional note. Exchange-level
records also snapshot the question and trust tag.

Trajectories carry no record of how each answer was tagged when it was
produced, so the viewer derives trust levels from the tool calls in the
trajectory: answers backed only by governed tools (`call_measure`,
`call_metrics`) are verified, and answers that used fallback tools
(`run_sql`, `run_r`) count as cited when they contain citation markup
and untrusted when they don't. A cited answer's quotes render as
footnotes so they can be reviewed, but they are not re-verified against
the agent's context: footnotes name no source and are attributed
"unverified".

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
