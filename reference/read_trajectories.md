# Read commons trajectories

`read_trajectories()` reads conversation trajectories written by
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
when logging is enabled via its `log` argument (for example
`log = TRUE`, a local directory path, or a
[`log_local()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/log_pins.md)
or
[`log_pins()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/log_pins.md)
spec).

## Usage

``` r
read_trajectories(x = NULL, ...)
```

## Arguments

- x:

  A `pins` board or a local directory path. If `NULL`, reads from the
  local
  [`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
  log directory.

- ...:

  Reserved for future extensions.

## Value

A list of lists of ellmer turns, one list per conversation.

## Agent skill

commons includes an agent skill scaffold for iterating on a deployed
agent. To locate it:

    system.file("skills", "commons", "SKILL.md", package = "commons")

To use it, copy the skill directory into your agent's skills directory,
like `./.agents/skills`:

    skill <- system.file("skills", "commons", package = "commons")
    dir.create("./.agents/skills", recursive = TRUE, showWarnings = FALSE)
    file.copy(skill, "./.agents/skills", recursive = TRUE)
