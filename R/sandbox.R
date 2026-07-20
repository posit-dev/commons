# R side of the worker sandbox (src/sandbox.c). These run inside the run_r
# worker process, which restricts itself before accepting model code; the
# parent process is never sandboxed.

# Report what the running kernel supports: the Landlock ABI version (-1 when
# unavailable) and whether seccomp filters can be installed.
sandbox_capabilities <- function() {
  caps <- .Call(c_sandbox_capabilities)
  list(landlock_abi = caps[[1]], seccomp = caps[[2]] > 0)
}

# Irreversibly restrict the calling process: filesystem access limited to the
# given roots (Landlock), no network and no reading other processes' memory
# (seccomp), optionally an address-space cap. Errors if any layer can't be
# applied — on Linux the sandbox must engage (deployment is Linux; fail
# closed). On other OSes this is silently a no-op; local dev is the only
# place commons runs off Linux.
sandbox_engage <- function(read_roots, write_roots, memory_limit = NULL) {
  if (!identical(Sys.info()[["sysname"]], "Linux")) {
    return(invisible(FALSE))
  }
  if (!is.null(memory_limit)) {
    memory_limit <- as.numeric(memory_limit)
  }
  .Call(c_sandbox_engage, unique(read_roots), unique(write_roots), memory_limit)
  invisible(TRUE)
}

# Everything the worker may read: R itself, the package libraries, and the
# system directories R and graphics need at runtime (locales, iconv,
# fontconfig). Landlock resolves symlinks to their real targets, so the
# resolved package directories are included too — on Posit Connect, the
# content's packrat library is a farm of symlinks into a shared cache.
sandbox_read_roots <- function() {
  pkg_dirs <- list.dirs(.libPaths(), recursive = FALSE)
  resolved <- vapply(
    pkg_dirs,
    function(p) tryCatch(normalizePath(p), error = function(e) p),
    character(1),
    USE.NAMES = FALSE
  )
  roots <- unique(c(
    R.home(),
    .libPaths(),
    resolved,
    "/usr", "/lib", "/lib64", "/etc", "/opt/R"
  ))
  roots[dir.exists(roots)]
}
