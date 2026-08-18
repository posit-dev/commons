# R side of the worker sandbox (src/sandbox.c). The run_r worker engages the
# sandbox itself in worker_init() (run-r.R), calling the C symbol directly;
# the parent process is never sandboxed.

nsjail_log <- function(format, ...) {
  cat(
    "[commons][nsjail] ",
    sprintf(format, ...),
    "\n",
    sep = "",
    file = stdout()
  )
}

sandbox_capabilities <- function() {
  caps <- .Call(c_sandbox_capabilities)
  nsjail <- nsjail_path()
  list(
    landlock_abi = caps[[1]],
    seccomp = caps[[2]] > 0,
    seatbelt = caps[[3]] > 0,
    userns = caps[[4]] > 0,
    nsjail = nzchar(nsjail) && file.access(nsjail, mode = 1) == 0
  )
}

run_r_sandbox_mode <- function() {
  match.arg(
    getOption("commons.run_r_sandbox", "auto"),
    c("auto", "landlock", "userns", "nsjail")
  )
}

check_run_r_sandbox <- function(
  capabilities = sandbox_capabilities(),
  sysname = Sys.info()[["sysname"]],
  sandbox_mode = run_r_sandbox_mode(),
  call = rlang::caller_env()
) {
  if (identical(sandbox_mode, "nsjail")) {
    path <- nsjail_path()
    nsjail_log(
      "requested: binary=%s executable=%s seccomp=%s userns=%s",
      if (nzchar(path)) path else "<not found>",
      nzchar(path) && file.access(path, mode = 1) == 0,
      capabilities$seccomp,
      capabilities$userns
    )
  }
  if (identical(sandbox_mode, "nsjail") && !identical(sysname, "Linux")) {
    cli::cli_abort(
      "{.code nsjail} is only supported on Linux.",
      call = call
    )
  }
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
  if (identical(sandbox_mode, "nsjail")) {
    if (!capabilities$nsjail) {
      cli::cli_abort(
        "commons cannot sandbox the {.code run_r} session because {.code nsjail}
         is not installed or is not executable.",
        call = call
      )
    }
    if (!capabilities$userns) {
      cli::cli_abort(
        "commons cannot sandbox the {.code run_r} session with {.code nsjail}
         because this host does not allow unprivileged user namespaces.",
        call = call
      )
    }
    return(invisible())
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
