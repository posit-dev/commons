# Review commons trajectories

`trajectory_review()` launches a Shiny app for browsing conversation
trajectories read with
[`trajectory_read()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/trajectory_read.md).
The app charts each trust level's share of answers over time—binned by
day, week, or month, using the finest unit the volume of answers
supports—alongside a list of questions grouped by conversation,
filterable by date and trust level. The transcript uses the same Commons
and ShinyChat renderer as live conversations, preserving recorded
messages and tool activity without a separate reviewer-specific
rendering path.

Transcripts are reviewable rather than live: conversations and questions
can be flagged for review and annotated with notes. Notes apply to the
whole conversation, or to a single question-and-answer exchange selected
in the transcript. Flags and notes are stored as one generated Markdown
document per reviewed conversation and are restored when the viewer
reopens.

Each Markdown document contains the complete reviewer-visible
conversation and its tool activity. YAML frontmatter stores active flags
and note history so the reviewer can restore its state and agents can
identify flagged conversations, exchanges, and reviewer notes. The
Markdown body is the human-readable transcript for joint human-agent
review. Search-pool results are omitted because later tool calls record
any selected measure; other tool results are limited to 50 lines or
20,000 characters.

Trust filters use each answer's tag exactly as
[`trajectory_read()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/trajectory_read.md)
recorded it. Missing or conflicting records are omitted rather than
inferred.

Logged calls that aren't part of the agent's question-and-answer record—
shinychat's conversation-title generation, and completions with no user
turn—are excluded from the viewer.

## Usage

``` r
trajectory_review(trajectories = trajectory_read(), review_dir = NULL)
```

## Arguments

- trajectories:

  A named list of conversations, as returned by
  [`trajectory_read()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/trajectory_read.md).

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

Files in a Posit Connect app's working directory are replaced on
redeployment. Review apps should use one Connect process because
separate processes do not coordinate file writes or in-memory review
state.

All sessions of one reviewer app share the same flags and notes; review
state is not separated by user. Notes record `session$user`, the login
information supplied by the Shiny host, or `"unknown"` when it is
unavailable. Flags do not record who changed them.

## Examples

``` r
if (FALSE) { # \dontrun{
trajectory_review()

trajectory_review(trajectory_read(from = "2026-07-01"))

Sys.setenv(COMMONS_REVIEW_DIR = "/path/to/persistent/reviews")
trajectory_review()
} # }
```
