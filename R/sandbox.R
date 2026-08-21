# R side of the worker sandbox (src/sandbox.c). The run_r worker engages the
# sandbox itself in worker_init() (run-r.R), calling the C symbol directly;
# the parent process is never sandboxed.

sandbox_capabilities <- function() {
  caps <- .Call(c_sandbox_capabilities)
  list(
    landlock_abi = caps[[1]],
    seccomp = caps[[2]] > 0,
    seatbelt = caps[[3]] > 0,
    userns = caps[[4]] > 0
  )
}

run_r_sandbox_support <- function(
  capabilities = sandbox_capabilities(),
  sysname = Sys.info()[["sysname"]]
) {
  if (identical(sysname, "Darwin")) {
    if (capabilities$seatbelt) {
      return(new_run_r_sandbox_support(TRUE))
    }
    return(new_run_r_sandbox_support(
      FALSE,
      "This macOS host does not provide Seatbelt sandboxing."
    ))
  }

  if (!identical(sysname, "Linux")) {
    return(new_run_r_sandbox_support(
      FALSE,
      sprintf("Sandboxing is not supported on %s.", sysname)
    ))
  }

  if (!capabilities$seccomp) {
    return(new_run_r_sandbox_support(
      FALSE,
      "This Linux host does not support seccomp."
    ))
  }
  if (capabilities$landlock_abi >= 1 || capabilities$userns) {
    return(new_run_r_sandbox_support(TRUE))
  }

  new_run_r_sandbox_support(
    FALSE,
    paste(
      "This Linux host offers neither Landlock nor unprivileged user",
      "namespaces."
    )
  )
}

new_run_r_sandbox_support <- function(available, reason = NULL) {
  list(available = available, reason = reason)
}

warn_run_r_unavailable <- function(support) {
  cli::cli_warn(
    c(
      "Disabling {.code run_r} because commons cannot sandbox it.",
      i = support$reason,
      i = paste(
        "The agent can still query data and use trusted calculations, but",
        "cannot perform ad hoc R analysis or plotting."
      ),
      i = paste0(
        "See <https://posit-dev.github.io/commons/articles/",
        "commons.html#run-r-sandboxing>."
      )
    ),
    .frequency = "once",
    .frequency_id = "commons_run_r_sandbox_unavailable"
  )
}
