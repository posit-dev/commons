`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

source("R/run-r.R")

outside <- file.path(
  dirname(tempdir()),
  paste0("commons-nsjail-canary-", Sys.getpid())
)
dir.create(outside)
on.exit(unlink(outside, recursive = TRUE), add = TRUE)
writeLines("secret", file.path(outside, "secret.txt"))

worker <- new_r_worker(network = "none", sandbox_mode = "nsjail")
on.exit(worker_close(worker), add = TRUE)
worker_ensure(worker)

probes <- worker$rs$call(
  function(outside) {
    denied <- function(expr) {
      tryCatch(
        {
          expr
          FALSE
        },
        error = function(e) TRUE,
        warning = function(w) TRUE
      )
    }
    list(
      read = denied(readLines(file.path(outside, "secret.txt"), n = 1)),
      write = denied(file.create(file.path(outside, "written.txt"))),
      socket = denied({
        con <- serverSocket(0)
        close(con)
      }),
      compute = sum(1:10)
    )
  },
  args = list(outside = outside)
)

stopifnot(
  isTRUE(probes$read),
  isTRUE(probes$write),
  isTRUE(probes$socket),
  identical(probes$compute, 55)
)
message("nsjail smoke test passed")
