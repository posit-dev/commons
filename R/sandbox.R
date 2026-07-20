# R side of the worker sandbox (src/sandbox.c). The run_r worker engages the
# sandbox itself in worker_init() (run-r.R), calling the C symbol directly;
# the parent process is never sandboxed.

# Report what the running kernel supports: the Landlock ABI version (-1 when
# unavailable) and whether seccomp filters can be installed.
sandbox_capabilities <- function() {
  caps <- .Call(c_sandbox_capabilities)
  list(landlock_abi = caps[[1]], seccomp = caps[[2]] > 0)
}
