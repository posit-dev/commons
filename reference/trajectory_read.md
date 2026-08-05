# Read commons trajectories

`trajectory_read()` reads conversation trajectories captured by
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
when `log = TRUE`. Trajectories are recorded as OpenTelemetry spans—see
the `log` argument of
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
for how capture is enabled—and read back from Posit Connect's content
observability store or from local trace files.

## Usage

``` r
trajectory_read(source = NULL, ..., n = NULL, from = NULL, to = NULL)
```

## Arguments

- source:

  Where to read trajectories from:

  - `NULL` (the default) resolves automatically: on Posit Connect, this
    content's own traces; in a project that has been deployed with
    rsconnect, the deployed content's traces; otherwise, the local trace
    directory that
    [`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
    writes to.

  - A Connect content GUID, a content URL (`.../content/<guid>/`), or a
    dashboard URL (`.../connect/#/apps/<guid>/`).

  - A directory of OTLP NDJSON trace files (`trace-*.jsonl`).

- ...:

  These dots are for future extensions and must be empty.

- n:

  Keep only the `n` most recent conversations, after `from`/`to`
  filtering. `NULL` (the default) keeps all of them.

- from, to:

  Keep only conversations with chat activity at or after `from` and
  before `to`. Each is a `POSIXct`, a `Date`, or a single string in a
  standard format like `"2026-07-22"` or `"2026-07-22 14:30:00"`; dates
  and strings are interpreted in local time. A conversation that
  continues past `to` is returned with its history as of `to`.

## Value

A list of conversations, named by conversation id and ordered
oldest-first. Each conversation is a list of
[ellmer::Turn](https://ellmer.tidyverse.org/reference/Turn.html)s and
carries a `last_active` attribute: a `POSIXct` giving the time of the
conversation's most recent chat activity. The list carries a `source`
attribute identifying the local trace directory or Connect content from
which it was read.

## Details

Reading traces from Connect requires the `CONNECT_API_KEY` environment
variable (and `CONNECT_SERVER`, when the server can't be inferred from
the project's deployment record), and editor-level access to the
content: you must own it or be a collaborator. See the `share_with`
argument of
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md).

## Agent skill

commons includes an agent skill scaffold for iterating on a deployed
agent. To locate it:

    system.file("skills", "commons", "SKILL.md", package = "commons")

To use it, copy the skill directory into your agent's skills directory,
like `./.agents/skills`:

    skill <- system.file("skills", "commons", package = "commons")
    dir.create("./.agents/skills", recursive = TRUE, showWarnings = FALSE)
    file.copy(skill, "./.agents/skills", recursive = TRUE)
