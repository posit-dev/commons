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

check_run_r_sandbox <- function(
  capabilities = sandbox_capabilities(),
  sysname = Sys.info()[["sysname"]],
  call = rlang::caller_env()
) {
  if (!identical(sysname, "Linux")) {
    return(invisible())
  }

  if (!capabilities$seccomp) {
    cli::cli_abort(
      "commons cannot sandbox the {.code run_r} session because this Linux
       host does not support seccomp.",
      call = call
    )
  }
  if (capabilities$landlock_abi >= 1 || capabilities$userns) {
    return(invisible())
  }

  cli::cli_abort(
    c(
      "commons cannot sandbox the {.code run_r} session because this Linux
       host offers neither Landlock nor unprivileged user namespaces.",
      i = "Use a kernel with Landlock, or enable unprivileged user namespaces.",
      i = "Check {.code sysctl user.max_user_namespaces} and, in a container,
           its seccomp profile."
    ),
    call = call
  )
}
