# Read commons trajectories

`read_trajectories()` reads conversation trajectories captured by
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
when `log = TRUE`. Trajectories are recorded as OpenTelemetry spans—see
the `log` argument of
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
for how capture is enabled—and read back from Posit Connect's content
observability store or from local trace files.

## Usage

``` r
read_trajectories(source = NULL)
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

## Value

A list of conversations, named by conversation id and ordered
oldest-first. Each conversation is a list of
[ellmer::Turn](https://ellmer.tidyverse.org/reference/Turn.html)s.

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
