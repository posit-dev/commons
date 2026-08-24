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

run_r_protection_mode <- function(
  capabilities = sandbox_capabilities(),
  sysname = Sys.info()[["sysname"]],
  allow_guardrails = isTRUE(getOption(
    "commons.dangerously_disable_sandbox",
    FALSE
  )),
  call = rlang::caller_env()
) {
  sandbox_available <- switch(
    sysname,
    Linux = capabilities$seccomp &&
      (capabilities$landlock_abi >= 1 || capabilities$userns),
    Darwin = capabilities$seatbelt,
    FALSE
  )
  if (sandbox_available) {
    return("sandbox")
  }
  if (allow_guardrails) {
    return("guardrails")
  }

  if (identical(sysname, "Linux") && !capabilities$seccomp) {
    cli::cli_abort(
      c(
        "commons cannot sandbox the {.code run_r} session because this Linux
         host does not support seccomp.",
        i = "For local development only, explicitly accept best-effort R
             guardrails with
             {.code options(commons.dangerously_disable_sandbox = TRUE)}."
      ),
      call = call
    )
  }
  if (identical(sysname, "Linux")) {
    cli::cli_abort(
      c(
        "commons cannot sandbox the {.code run_r} session because this Linux
         host offers neither Landlock nor unprivileged user namespaces.",
        i = "Use a kernel with Landlock, or enable unprivileged user namespaces.",
        i = "Check {.code sysctl user.max_user_namespaces} and, in a container,
             its seccomp profile.",
        i = "For local development only, explicitly accept best-effort R
             guardrails with
             {.code options(commons.dangerously_disable_sandbox = TRUE)}."
      ),
      call = call
    )
  }

  cli::cli_abort(
    c(
      "commons cannot sandbox the {.code run_r} session on {sysname}.",
      i = "For local development only, explicitly accept best-effort R
           guardrails with
           {.code options(commons.dangerously_disable_sandbox = TRUE)}.",
      i = "These guardrails are not a security boundary."
    ),
    call = call
  )
}
