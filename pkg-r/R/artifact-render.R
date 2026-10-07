# Renders run one at a time per agent, each in a fresh sandboxed worker, so
# model-written cells get the same isolation as run_r and a document can't
# depend on state it doesn't declare.
artifact_render_queued <- function(store, dir) {
  tail <- store$tail %||% promises::promise_resolve(NULL)
  chain <- promises::then(tail, function(...) {
    render_artifact(dir, store$network, store$protection)
  })
  store$tail <- promises::catch(chain, function(err) NULL)
  promises::catch(chain, function(err) list(error = conditionMessage(err)))
}

# Resolves to `list(html = )` on success and `list(error = )` otherwise. The
# source directory is copied into the worker's own, so rendering writes
# nothing next to the saved version but its HTML.
render_artifact <- function(
  dir,
  network = "none",
  protection = "sandbox",
  timeout = getOption("commons.artifact_render_timeout", 120)
) {
  quarto <- quarto_binary()
  if (is.null(quarto)) {
    return(promises::promise_resolve(list(error = paste(
      "Quarto is not installed where this app runs, so documents can't be",
      "rendered. This is not a problem with the document; don't change it",
      "to fix this."
    ))))
  }

  work_dir <- tempfile("commons-render-")
  dir.create(work_dir)
  doc_dir <- file.path(work_dir, "doc")
  dir.create(doc_dir)
  file.copy(list.files(dir, full.names = TRUE), doc_dir, recursive = TRUE)

  worker <- new.env(parent = emptyenv())
  worker$rs <- callr::r_session$new(
    callr::r_session_options(
      env = worker_scrubbed_env(work_dir, worker_single_thread("auto"))
    ),
    wait = TRUE
  )
  cleanup <- function() {
    try(worker$rs$close(), silent = TRUE)
    unlink(work_dir, recursive = TRUE)
  }
  started <- tryCatch(
    {
      worker$rs$run(
        worker_call,
        args = list(
          runtime = worker_runtime(),
          name = "worker_init",
          args = list(
            parent_tmp = tempdir(),
            work_dir = work_dir,
            dll_path = commons_dll_path(),
            network = network,
            protection = protection,
            extra_read_roots = quarto_root(quarto)
          )
        )
      )
      worker$rs$call(
        worker_call,
        args = list(
          runtime = worker_runtime(),
          name = "worker_render_quarto",
          args = list(quarto = quarto, doc_dir = doc_dir, timeout = timeout)
        )
      )
      TRUE
    },
    error = function(err) err
  )
  if (inherits(started, "error")) {
    cleanup()
    return(promises::promise_resolve(list(
      error = paste("The render could not start:", conditionMessage(started))
    )))
  }

  rendered <- promises::then(
    worker_await(worker, timeout = timeout + 10),
    function(res) {
      if (!is.null(res$failure)) {
        return(list(error = paste("The render failed:", res$failure)))
      }
      html_path <- file.path(doc_dir, "report.html")
      if (res$status != 0L || !file.exists(html_path)) {
        return(list(error = quarto_error_text(res$output, res$timeout)))
      }
      file.copy(html_path, dir, overwrite = TRUE)
      list(html = read_utf8(html_path))
    }
  )
  promises::finally(rendered, cleanup)
}

quarto_error_text <- function(output, timed_out = FALSE) {
  if (isTRUE(timed_out)) {
    return("Rendering took too long and was stopped.")
  }
  lines <- strsplit(cli::ansi_strip(output %||% ""), "\n", fixed = TRUE)[[1]]
  lines <- lines[nzchar(trimws(lines))]
  paste(c("Quarto reported:", utils::tail(lines, 30)), collapse = "\n")
}

quarto_binary <- function() {
  path <- Sys.getenv("QUARTO_PATH")
  if (!nzchar(path)) {
    path <- Sys.which("quarto")[[1]]
  }
  if (!nzchar(path) || !file.exists(path)) {
    return(NULL)
  }
  normalizePath(path)
}

# The sandbox must let the worker read Quarto's whole installation: its
# launcher script, Deno, Pandoc, and their resources.
quarto_root <- function(quarto) {
  dirname(dirname(quarto))
}

read_utf8 <- function(path) {
  paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
}

artifact_zip <- function(store, id, file) {
  artifact <- artifact_get(store, id)
  if (is.null(artifact)) {
    cli::cli_abort("There is no document with id {.val {id}}.")
  }
  dir <- artifact_latest_dir(artifact)
  old <- setwd(dir)
  on.exit(setwd(old), add = TRUE)
  utils::zip(
    normalizePath(file, mustWork = FALSE),
    files = list.files(".", recursive = TRUE, all.files = FALSE),
    flags = "-r9Xq"
  )
}
