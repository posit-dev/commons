# Configure where commons logs conversation trajectories

Pass one of these to the `log` argument of
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md)
for control over where trajectories are written. `log_pins()` writes to
private Connect pins; `log_local()` writes to a local directory.

## Usage

``` r
log_pins(share_with = NULL)

log_local(path = NULL)
```

## Arguments

- share_with:

  An optional character vector of Connect usernames to grant viewer
  access to logged trajectory pins. Requires the connectapi package.
  Access is granted as each conversation's pin is created, so named
  users retain ongoing access to new trajectories.

- path:

  A directory to write trajectory files to. Defaults to the
  `COMMONS_LOG_DIR` environment variable, or a temporary directory.

## Value

A logging spec to pass to the `log` argument of
[`commons()`](https://solid-adventure-ny1mpqy.pages.github.io/reference/commons.md).
