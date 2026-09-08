tool_run_r <- function(private) {
  handle_tools <- c(
    if (length(private$registry) > 0) "call_measure",
    if (
      registry_has_metrics(private$definitions) ||
        semantic_registry_has_metrics(private$semantic_models) ||
        sources_have_semantic_stubs(private$sources)
    ) {
      "call_metrics"
    },
    if (
      length(private$calculations) ||
        sources_have_semantic_stubs(
          private$sources,
          backend = "snowflake_semantic_view"
        )
    ) {
      "call_calculation"
    },
    "run_sql"
  )
  ellmer::tool(
    function(code) {
      promises::then(
        run_r_tool(private$worker, private$handles, code, private$fn_sources),
        function(res) add_citation_request(res, private$citation_request)
      )
    },
    paste(
      # The model sees OS-sandbox framing even when Windows uses guardrails.
      "Run R code in your sandboxed R session to analyze results or render plots.",
      "R code and textual output are visible only to you; rendered plots are",
      "also shown to the user.",
      "The user cannot access or interact with this session. Never direct them",
      "to run code or inspect its variables or files; perform follow-up analysis",
      "yourself and report the result in your response.",
      "Your session persists across calls: variables you assign and packages",
      "you load remain available.",
      cli::format_inline(
        "Results from {handle_tools} are preloaded as variables (r1, r2, ...)."
      ),
      if (length(private$registry) > 0) {
        paste(
          "Measure definitions and their helper functions are predefined under",
          "their own names: evaluate a measure's name to read its source.",
          "These are source-only copies without their original environment or",
          "database connections, so treat them as reference material; to compute",
          "a measure, use call_measure."
        )
      },
      "\n\nRules:",
      "\n- Work incrementally: each call should do one small, well-defined task.",
      "\n- Prefer tidyverse style: put separate expressions on separate lines",
      "and wrap long calls for readability.",
      "\n- Create at most one figure per call and return it implicitly rather",
      "than saving it.",
      "\n- Do not use this tool to talk to the user; explanations belong in your reply.",
      "\n- Return results implicitly (`x`, not `print(x)`) and prefer brief",
      "summaries (head(), summary()) over large outputs.",
      "\n- The session can only write to its own temporary directory.",
      if (identical(private$worker$network, "none")) {
        "\n- The session has no network access."
      } else {
        paste(
          "\n- The temporary directory has been added to libPaths, so you",
          "can use install.packages() normally."
        )
      }
    ),
    arguments = list(
      code = ellmer::type_string("The R code to run.")
    ),
    name = "run_r",
    annotations = ellmer::tool_annotations(
      title = "Analyzing data",
      icon = maybe_icon("terminal"),
      read_only_hint = FALSE,
      open_world_hint = identical(private$worker$network, "full")
    )
  )
}

# Returns a promise so a long computation doesn't block other sessions'
# chats. Calls are chained through worker$tail so concurrent tool calls
# within a turn take turns on the single worker process.
run_r_tool <- function(worker, handles, code, fn_sources = character()) {
  task <- function(...) {
    tryCatch(
      {
        worker_ensure(worker, fn_sources)
        ids <- handle_ids(handles)
        new_ids <- ids[seq_along(ids) > worker$synced]
        new_handles <- lapply(
          rlang::set_names(new_ids),
          function(id) get_handle(handles, id)
        )
        dims <- plot_dimensions()
        # Recreate entry points outside the model's global environment for
        # each call.
        worker$rs$call(
          worker_call,
          args = list(
            runtime = worker$runtime,
            name = "worker_run_code",
            args = list(
              code = code,
              new_handles = new_handles,
              plot_width = dims$width,
              plot_height = dims$height,
              evaluate = evaluate::evaluate,
              new_output_handler = evaluate::new_output_handler
            )
          )
        )
        worker$synced <- length(ids)
        worker_await(worker)
      },
      error = function(e) {
        list(failure = conditionMessage(e))
      }
    )
  }

  worker$pending <- worker$pending + 1L
  chain <- promises::then(worker_tail(worker), onFulfilled = task)
  worker$tail <- promises::catch(chain, function(e) NULL)

  # Decrement exactly once, whether the call succeeded or failed: this and
  # run_r_result() below are separate promise handlers that could both fire,
  # and a double decrement could let schedule_worker_reap() close the worker
  # while another call is still in flight.
  settled <- promises::finally(chain, function() {
    worker$pending <- worker$pending - 1L
    schedule_worker_reap(worker)
  })
  promises::then(settled, function(res) run_r_result(code, res))
}

run_r_result <- function(code, res) {
  if (!is.null(res$failure)) {
    return(tool_result(
      sprintf("Error: %s", res$failure),
      title = "Analyzed data",
      icon = maybe_icon("terminal"),
      html = run_r_html(code, list(list(type = "error", text = res$failure))),
      tag = "B",
      show_tag = FALSE
    ))
  }

  segments <- res$segments
  has_plot <- any(
    vapply(segments, function(seg) seg$type == "plot", logical(1))
  )
  tool_result(
    run_r_value(segments),
    title = "Analyzed data",
    icon = maybe_icon("terminal"),
    html = run_r_html(code, segments),
    tag = "B",
    open = has_plot,
    show_tag = FALSE
  )
}

# The model-facing value: text segments merged in order, plots as inline
# images so the model sees what it plotted. Source segments are dropped —
# the model already knows what it wrote.
run_r_value <- function(segments) {
  out <- list()
  buffer <- character()
  flush <- function() {
    if (length(buffer)) {
      out[[length(out) + 1L]] <<- ellmer::ContentText(
        text = paste(buffer, collapse = "\n")
      )
      buffer <<- character()
    }
  }

  for (seg in segments) {
    switch(
      seg$type,
      source = NULL,
      plot = {
        flush()
        out[[length(out) + 1L]] <- ellmer::content_image_file(
          seg$path,
          resize = "none"
        )
      },
      warning = buffer <- c(buffer, paste0("Warning: ", seg$text)),
      error = buffer <- c(buffer, paste0("Error: ", seg$text)),
      buffer <- c(buffer, seg$text)
    )
  }
  flush()

  if (any(vapply(segments, function(seg) seg$type == "plot", logical(1)))) {
    out[[length(out) + 1L]] <- ellmer::ContentText(
      visible_result_note("plot")
    )
  }

  if (length(out) == 0) {
    return("(The code ran but produced no output.)")
  }
  all_text <- all(
    vapply(out, function(x) S7::S7_inherits(x, ellmer::ContentText), logical(1))
  )
  if (all_text) {
    return(paste(
      vapply(out, function(x) x@text, character(1)),
      collapse = "\n"
    ))
  }
  out
}

run_r_html <- function(code, segments) {
  plot_html <- character()
  output <- character()
  for (seg in segments) {
    if (seg$type == "source") {
      next
    }
    if (seg$type == "plot") {
      plot_html <- c(plot_html, sprintf(
        "<img class=\"commons-run-r-plot\" src=\"data:image/png;base64,%s\" alt=\"Plot produced by R code\"/>",
        jsonlite::base64_enc(readBin(
          seg$path,
          "raw",
          file.size(seg$path)
        ))
      ))
    } else {
      output <- c(
        output,
        paste0("#> ", strsplit(seg$text, "\n", fixed = TRUE)[[1]])
      )
    }
  }
  code_html <- sprintf(
    "<pre class=\"commons-run-r-code\"><code class=\"language-r\">%s</code></pre>",
    highlight_r_html(paste(c(code, output), collapse = "\n"))
  )
  if (length(plot_html)) {
    code_html <- paste0(
      "<details class=\"commons-run-r-details\"><summary>Details</summary>",
      code_html,
      "</details>"
    )
  }
  sprintf(
    "<div class=\"commons-run-r-display\">%s</div>",
    paste(c(code_html, plot_html), collapse = "\n")
  )
}

highlight_r_html <- function(code) {
  fallback <- tryCatch(
    {
      parse(text = code)
      FALSE
    },
    error = function(...) TRUE
  )
  paste(highr::hi_html(code, fallback = fallback), collapse = "\n")
}

# --- worker lifecycle --------------------------------------------------------

new_r_worker <- function(network = "none", protection = "sandbox") {
  protection <- rlang::arg_match(protection, c("sandbox", "guardrails"))
  worker <- new.env(parent = emptyenv())
  worker$network <- network
  worker$protection <- protection
  worker$rs <- NULL
  worker$synced <- 0L
  worker$tail <- NULL
  worker$pending <- 0L
  worker$reap <- NULL
  worker$last_used <- Sys.time()
  worker$runtime <- worker_runtime()
  # Close the child process when the agent is garbage-collected, so a session
  # that ends without idling out doesn't leak an R process.
  reg.finalizer(worker, worker_close, onexit = TRUE)
  worker
}

worker_tail <- function(worker) {
  worker$tail %||% promises::promise_resolve(NULL)
}

worker_ensure <- function(worker, fn_sources = character()) {
  if (!is.null(worker$rs) && worker$rs$is_alive()) {
    return(invisible(worker))
  }
  work_dir <- tempfile("commons-worker-")
  dir.create(work_dir, recursive = TRUE)
  rs <- callr::r_session$new(
    callr::r_session_options(
      env = worker_scrubbed_env(work_dir, worker_single_thread("auto"))
    ),
    wait = TRUE
  )
  # Load the worker runtime before engaging the sandbox. No user-provided code
  # runs until the sandbox is active.
  rs$run(
    worker_call,
    args = list(
      runtime = worker$runtime,
      name = "worker_init",
      args = list(
        parent_tmp = tempdir(),
        work_dir = work_dir,
        dll_path = commons_dll_path(),
        network = worker$network,
        protection = worker$protection
      )
    )
  )
  if (identical(worker$protection, "guardrails")) {
    # Build hooks in the worker so their captured functions stay worker-local.
    rs$run(
      worker_call,
      args = list(
        runtime = worker$runtime,
        name = "worker_guardrails",
        args = list(work_dir = work_dir, network = worker$network)
      )
    )
  }
  # Defining sources at spawn (rather than syncing per call like handles)
  # means a respawned worker gets them again for free.
  if (length(fn_sources)) {
    rs$run(
      worker_call,
      args = list(
        runtime = worker$runtime,
        name = "worker_define_functions",
        args = list(fn_sources = fn_sources)
      )
    )
  }
  worker$rs <- rs
  worker$synced <- 0L
  invisible(worker)
}

# unshare(CLONE_NEWUSER) requires a single-threaded process.
worker_single_thread <- function(sandbox_mode) {
  if (!identical(Sys.info()[["sysname"]], "Linux")) {
    return(FALSE)
  }
  switch(
    sandbox_mode,
    userns = TRUE,
    auto = sandbox_capabilities()$landlock_abi < 1,
    FALSE
  )
}

commons_dll_path <- function() {
  dll <- getLoadedDLLs()[["commons"]]
  if (is.null(dll)) {
    return(NA_character_)
  }
  dll[["path"]]
}

worker_close <- function(worker) {
  cancel_worker_reap(worker)
  if (!is.null(worker$rs)) {
    try(worker$rs$close(), silent = TRUE)
    worker$rs <- NULL
    worker$synced <- 0L
  }
  invisible(worker)
}

# The content environment holds credentials (API keys, session tokens,
# database URLs) that an OS sandbox can't hide, so the worker starts from an
# allowlist: callr applies `env` with withr semantics, where an NA unsets.
worker_scrubbed_env <- function(work_dir, single_thread = FALSE) {
  keep <- c(
    "PATH",
    "LANG",
    "LD_LIBRARY_PATH",
    "R_HOME",
    "R_LIBS",
    "R_LIBS_USER",
    "R_LIBS_SITE",
    "R_ENVIRON",
    "R_ENVIRON_USER",
    "R_PROFILE",
    "R_PROFILE_USER"
  )
  vars <- names(Sys.getenv())
  keep <- c(keep, vars[startsWith(vars, "LC_")])
  drop <- setdiff(vars, keep)
  env <- rlang::set_names(rep(NA_character_, length(drop)), drop)
  env[["TMPDIR"]] <- work_dir
  env[["HOME"]] <- work_dir
  if (single_thread) {
    env[["OPENBLAS_NUM_THREADS"]] <- "1"
    env[["OMP_NUM_THREADS"]] <- "1"
  }
  env
}

# The runtime lives outside R/ because it deliberately mutates only the child.
worker_script_path <- function() {
  system.file("worker", "worker.R", package = "commons", mustWork = TRUE)
}

worker_runtime <- function() {
  parse(worker_script_path(), keep.source = FALSE)
}

worker_call <- function(runtime, name, args) {
  runtime_env <- base::new.env(parent = base::baseenv())
  base::eval(runtime, envir = runtime_env)
  entry_point <- base::get(name, envir = runtime_env, inherits = FALSE)
  base::do.call(entry_point, args)
}

# Close the worker after a quiet stretch; it respawns lazily on the next
# call. One timer per worker, not one per call: shiny::testServer() reads its
# outputs through shiny:::wait_for_it(), which spins until the whole later
# queue drains, so a stray timer stalls the reader for its full delay.
schedule_worker_reap <- function(
  worker,
  idle = getOption("commons.run_r_idle_timeout", 600)
) {
  worker$last_used <- Sys.time()
  cancel_worker_reap(worker)
  worker$reap <- later::later(
    function() {
      quiet <- difftime(Sys.time(), worker$last_used, units = "secs") >= idle
      if (worker$pending == 0L && quiet) {
        worker_close(worker)
      }
    },
    delay = idle + 1
  )
  invisible(worker)
}

cancel_worker_reap <- function(worker) {
  if (!is.null(worker$reap)) {
    worker$reap()
    worker$reap <- NULL
  }
  invisible(worker)
}

# Resolve when the in-flight $call() completes, without blocking: later_fd
# watches the session's poll connection, the same mechanism ellmer itself
# uses for async HTTP. A wall-clock timeout interrupts the computation, and
# an unresponsive or crashed worker is killed (it respawns on the next call).
worker_await <- function(
  worker,
  timeout = getOption("commons.run_r_timeout", 60)
) {
  rs <- worker$rs
  promises::promise(function(resolve, reject) {
    settled <- FALSE
    timed_out <- FALSE
    cancel_kill <- NULL

    # later::later() and later::later_fd() each return their own canceller.
    # Hand every one of them back once the call settles, so a caller that
    # waits on later::loop_empty() is not held up by a timer for a call that
    # already finished. Calling one after its callback ran is a safe no-op.
    release <- function() {
      for (cancel in list(cancel_timeout, cancel_kill, cancel_watch)) {
        if (!is.null(cancel)) {
          cancel()
        }
      }
    }

    settle <- function(value) {
      if (!settled) {
        settled <<- TRUE
        release()
        resolve(value)
      }
    }
    kill_worker <- function(reason) {
      try(rs$close(), silent = TRUE)
      if (identical(worker$rs, rs)) {
        worker$rs <- NULL
        worker$synced <- 0L
      }
      settle(list(failure = reason))
    }

    cancel_timeout <- later::later(
      function() {
        if (settled) {
          return()
        }
        timed_out <<- TRUE
        try(rs$interrupt(), silent = TRUE)
        cancel_kill <<- later::later(
          function() {
            if (!settled) {
              kill_worker(sprintf(
                "the code exceeded the %d-second time limit and the R session did not respond to an interrupt, so it was restarted. Session variables were reset.",
                as.integer(timeout)
              ))
            }
          },
          delay = 5
        )
      },
      delay = timeout
    )

    fd <- processx::conn_get_fileno(rs$get_poll_connection())
    poll <- function() {
      later::later_fd(
        function(ready) {
          if (settled) {
            return()
          }
          msg <- tryCatch(rs$read(), error = function(e) NULL)
          if (is.null(msg)) {
            cancel_watch <<- poll()
          } else if (msg$code == 200) {
            if (timed_out) {
              settle(list(failure = sprintf(
                "the code was interrupted after exceeding the %d-second time limit. The session and its variables remain available.",
                as.integer(timeout)
              )))
            } else if (!is.null(msg$error)) {
              settle(list(failure = conditionMessage(msg$error)))
            } else {
              settle(msg$result)
            }
          } else if (msg$code >= 500) {
            kill_worker(
              "the R session crashed and was restarted. Session variables were reset."
            )
          } else {
            cancel_watch <<- poll()
          }
        },
        readfds = fd
      )
    }
    cancel_watch <- poll()
  })
}
