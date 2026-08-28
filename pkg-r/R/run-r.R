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
        # callr rebinds a transferred function's environment to the worker's
        # global env, so the entry point must be namespace-qualified.
        worker$rs$call(
          worker_run_code,
          args = list(
            code = code,
            new_handles = new_handles,
            plot_width = dims$width,
            plot_height = dims$height
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
  worker$last_used <- Sys.time()
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
  # callr rebinds a transferred function's environment to the worker's global
  # env, and the worker starts with a scrubbed, minimal package set, so the
  # worker entry points are self-contained (no commons internals by name). The
  # sandbox is reached by loading commons's compiled library by path, which
  # works whether commons is installed or loaded via load_all().
  rs$run(
    worker_init,
    args = list(
      parent_tmp = tempdir(),
      work_dir = work_dir,
      dll_path = commons_dll_path(),
      network = worker$network,
      protection = worker$protection
    )
  )
  if (identical(worker$protection, "guardrails")) {
    # Build hooks in the worker so their captured functions stay worker-local.
    rs$run(
      worker_guardrails,
      args = list(work_dir = work_dir, network = worker$network)
    )
  }
  # Defining sources at spawn (rather than syncing per call like handles)
  # means a respawned worker gets them again for free.
  if (length(fn_sources)) {
    rs$run(worker_define_functions, args = list(fn_sources = fn_sources))
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

worker_guardrails <- function(work_dir, network = "none") {
  normalize <- base::normalizePath
  file_exists <- base::file.exists
  dir_exists <- base::dir.exists
  path_exists <- function(path) {
    file_exists(path) || dir_exists(path)
  }
  canonical_path <- function(path) {
    path <- path.expand(path)
    if (!grepl("^([A-Za-z]:[/\\\\]|[/\\\\]{1,2})", path)) {
      path <- file.path(getwd(), path)
    }
    suffix <- character()
    # Resolving an existing ancestor exposes symlinks beneath nonexistent paths.
    while (!path_exists(path) && !identical(dirname(path), path)) {
      suffix <- c(basename(path), suffix)
      path <- dirname(path)
    }
    path <- normalize(path, winslash = "/", mustWork = FALSE)
    if (length(suffix)) {
      path <- do.call(file.path, as.list(c(path, suffix)))
    }
    if (nchar(path) > 1L && !grepl("^[A-Za-z]:/$", path)) {
      path <- sub("/+$", "", path)
    }
    path
  }
  canonical_paths <- function(paths) {
    unique(vapply(paths, canonical_path, character(1), USE.NAMES = FALSE))
  }
  package_dirs <- unlist(
    lapply(.libPaths(), base::list.dirs, recursive = FALSE, full.names = TRUE),
    use.names = FALSE
  )
  read_roots <- canonical_paths(c(R.home(), .libPaths(), package_dirs, work_dir))
  write_roots <- canonical_paths(work_dir)
  windows <- identical(Sys.info()[["sysname"]], "Windows")

  in_roots <- function(path, roots) {
    if (windows) {
      path <- tolower(path)
      roots <- tolower(roots)
    }
    any(vapply(
      roots,
      function(root) {
        identical(path, root) ||
          identical(root, "/") ||
          startsWith(path, paste0(root, "/"))
      },
      logical(1)
    ))
  }
  deny <- function(kind, target = NULL) {
    detail <- if (is.null(target)) "" else paste0(" to '", target, "'")
    stop("commons run_r guardrails denied ", kind, detail, call. = FALSE)
  }
  check_path <- function(paths, access) {
    if (is.null(paths)) {
      return(invisible())
    }
    if (inherits(paths, "connection")) {
      description <- tryCatch(
        summary(paths)$description,
        error = function(e) ""
      )
      if (
        !nzchar(description) ||
          description %in% c("stdin", "stdout", "stderr", "terminal") ||
          startsWith(description, "textConnection") ||
          startsWith(description, "rawConnection")
      ) {
        return(invisible())
      }
      paths <- description
    }
    paths <- as.character(paths)
    paths <- paths[!is.na(paths) & nzchar(paths)]
    for (path in paths) {
      uri <- grepl("^[A-Za-z][A-Za-z0-9+.-]*:", path) &&
        !grepl("^[A-Za-z]:[/\\\\]", path)
      if (uri) {
        if (startsWith(tolower(path), "file:")) {
          deny(paste(access, "access"), path)
        }
        if (identical(network, "none")) {
          deny("network access", path)
        }
        next
      }
      resolved <- canonical_path(path)
      roots <- if (identical(access, "write")) write_roots else read_roots
      if (!in_roots(resolved, roots)) {
        deny(paste(access, "access"), path)
      }
    }
    invisible()
  }
  namespace_function <- function(package, name) {
    get(name, envir = asNamespace(package), inherits = FALSE)
  }
  matched_arguments <- function(original, args) {
    call <- as.call(c(list(quote(.guarded_call)), args))
    names(call) <- c("", names(args))
    match.call(original, call, expand.dots = FALSE)
  }
  path_hook <- function(
    package,
    name,
    access,
    argument,
    dots = FALSE,
    exclude = character()
  ) {
    original <- namespace_function(package, name)
    replacement <- function(...) {
      args <- list(...)
      if (identical(name, "load") && is.null(args$envir)) {
        args$envir <- parent.frame()
      }
      matched <- matched_arguments(original, args)
      paths <- if (dots) {
        values <- as.list(matched$...)
        value_names <- names(values)
        if (is.null(value_names)) {
          value_names <- rep("", length(values))
        }
        values <- values[!nzchar(value_names) | !value_names %in% exclude]
        unlist(values, use.names = FALSE)
      } else if (!is.null(matched[[argument]])) {
        matched[[argument]]
      } else {
        NULL
      }
      check_path(paths, access)
      do.call(original, args)
    }
    list(package = package, name = name, replacement = replacement)
  }
  named_path_hook <- function(package, name, access, argument, default = NULL) {
    original <- namespace_function(package, name)
    replacement <- function(...) {
      args <- list(...)
      path <- args[[argument]]
      if (is.null(path)) {
        path <- default
      }
      check_path(path, access)
      do.call(original, args)
    }
    list(package = package, name = name, replacement = replacement)
  }
  pair_hook <- function(package, name, first_access, second_access) {
    original <- namespace_function(package, name)
    replacement <- function(...) {
      args <- list(...)
      matched <- matched_arguments(original, args)
      formal_names <- names(formals(original))
      check_path(matched[[formal_names[[1L]]]], first_access)
      check_path(matched[[formal_names[[2L]]]], second_access)
      do.call(original, args)
    }
    list(package = package, name = name, replacement = replacement)
  }
  arguments_hook <- function(package, name, accesses) {
    original <- namespace_function(package, name)
    replacement <- function(...) {
      args <- list(...)
      matched <- matched_arguments(original, args)
      for (argument in names(accesses)) {
        check_path(matched[[argument]], accesses[[argument]])
      }
      do.call(original, args)
    }
    list(package = package, name = name, replacement = replacement)
  }
  connection_hook <- function(name) {
    original <- namespace_function("base", name)
    replacement <- function(...) {
      args <- list(...)
      matched <- matched_arguments(original, args)
      description <- matched$description
      open <- matched$open
      if (is.null(description)) description <- ""
      if (is.null(open)) open <- ""
      access <- if (grepl("[wa+]", open)) "write" else "read"
      check_path(description, access)
      do.call(original, args)
    }
    list(package = "base", name = name, replacement = replacement)
  }
  open_connection_hook <- function() {
    original <- namespace_function("base", "open.connection")
    replacement <- function(con, open = "r", blocking = TRUE, ...) {
      access <- if (grepl("[wa+]", open)) "write" else "read"
      check_path(con, access)
      original(con, open = open, blocking = blocking, ...)
    }
    list(
      package = "base",
      name = "open.connection",
      replacement = replacement
    )
  }
  save_hook <- function() {
    original <- namespace_function("base", "save")
    replacement <- function(
      ...,
      list = character(),
      file = stop("'file' must be specified"),
      ascii = FALSE,
      version = NULL,
      envir = parent.frame(),
      compress = isTRUE(!ascii),
      compression_level,
      eval.promises = TRUE,
      precheck = TRUE
    ) {
      check_path(file, "write")
      dots <- as.list(substitute(list(...)))[-1L]
      dot_names <- vapply(dots, deparse1, character(1))
      args <- list(
        list = unique(c(dot_names, list)),
        file = file,
        ascii = ascii,
        version = version,
        envir = envir,
        compress = compress,
        eval.promises = eval.promises,
        precheck = precheck
      )
      if (!missing(compression_level)) {
        args$compression_level <- compression_level
      }
      do.call(original, args)
    }
    list(package = "base", name = "save", replacement = replacement)
  }
  denied_hook <- function(package, name, kind) {
    original <- namespace_function(package, name)
    replacement <- function(...) {
      deny(kind)
      do.call(original, list(...))
    }
    list(package = package, name = name, replacement = replacement)
  }

  read_arguments <- c(
    file.access = "names", list.files = "path", list.dirs = "path",
    dir = "path", normalizePath = "path", setwd = "dir",
    readLines = "con", readChar = "con", readBin = "con", scan = "file",
    dget = "file", load = "file", readRDS = "file", source = "file",
    sys.source = "file", parse = "file",
    read.dcf = "file", readRenviron = "path", dyn.load = "x"
  )
  write_arguments <- c(
    dir.create = "path", unlink = "x", Sys.chmod = "paths",
    Sys.setFileTime = "path", sink = "file"
  )
  pair_access <- list(
    file.rename = c("write", "write"),
    file.copy = c("read", "write"),
    file.append = c("write", "read"),
    file.symlink = c("read", "write"),
    file.link = c("read", "write")
  )
  hooks <- c(
    list(
      path_hook("base", "file.exists", "read", "...", dots = TRUE),
      path_hook("base", "dir.exists", "read", "paths"),
      path_hook(
        "base", "file.info", "read", "...", dots = TRUE,
        exclude = "extra_cols"
      ),
      path_hook("base", "Sys.readlink", "read", "paths"),
      path_hook("base", "Sys.glob", "read", "paths"),
      path_hook("base", "file.show", "read", "...", dots = TRUE)
    ),
    Map(
      function(name, argument) path_hook("base", name, "read", argument),
      names(read_arguments),
      unname(read_arguments)
    ),
    list(
      path_hook(
        "base", "file.create", "write", "...", dots = TRUE,
        exclude = "showWarnings"
      ),
      path_hook("base", "file.remove", "write", "...", dots = TRUE)
    ),
    Map(
      function(name, argument) path_hook("base", name, "write", argument),
      names(write_arguments),
      unname(write_arguments)
    ),
    list(
      path_hook("base", "writeLines", "write", "con"),
      path_hook("base", "writeChar", "write", "con"),
      path_hook("base", "writeBin", "write", "con"),
      path_hook("base", "dput", "write", "file"),
      path_hook("base", "saveRDS", "write", "file"),
      path_hook("base", "write.dcf", "write", "file"),
      named_path_hook("base", "cat", "write", "file", ""),
      save_hook()
    ),
    Map(
      function(name, access) {
        pair_hook("base", name, access[[1L]], access[[2L]])
      },
      names(pair_access),
      unname(pair_access)
    ),
    lapply(c("file", "gzfile", "bzfile", "xzfile", "fifo"), connection_hook),
    list(
      path_hook("base", "unz", "read", "description"),
      open_connection_hook()
    ),
    lapply(
      c("system", "system2", "pipe"),
      function(name) denied_hook("base", name, "subprocess creation")
    ),
    list(denied_hook("utils", "browseURL", "subprocess creation"))
  )
  if (exists("shell", envir = baseenv(), inherits = FALSE)) {
    hooks <- c(hooks, list(denied_hook("base", "shell", "subprocess creation")))
  }
  for (package in c("base", "utils")) {
    namespace <- asNamespace(package)
    if (exists("shell.exec", envir = namespace, inherits = FALSE)) {
      hooks <- c(
        hooks,
        list(denied_hook(package, "shell.exec", "subprocess creation"))
      )
    }
  }
  if (identical(network, "none")) {
    hooks <- c(
      hooks,
      lapply(
        c("url", "socketConnection", "serverSocket", "socketAccept"),
        function(name) denied_hook("base", name, "network access")
      ),
      lapply(
        c("download.file", "url.show"),
        function(name) denied_hook("utils", name, "network access")
      )
    )
  } else {
    hooks <- c(
      hooks,
      list(
        connection_hook("url"),
        pair_hook("utils", "download.file", "read", "write"),
        arguments_hook(
          "utils",
          "url.show",
          c(url = "read", file = "write")
        )
      )
    )
  }
  attach(NULL, name = "commons:guardrails")
  assign(
    ".commons_guardrails",
    hooks,
    envir = as.environment("commons:guardrails")
  )
  invisible(TRUE)
}

# Close the worker after a quiet stretch; it respawns lazily on the next
# call. Stray timers are harmless: they check recency before acting.
schedule_worker_reap <- function(
  worker,
  idle = getOption("commons.run_r_idle_timeout", 600)
) {
  worker$last_used <- Sys.time()
  later::later(
    function() {
      quiet <- difftime(Sys.time(), worker$last_used, units = "secs") >= idle
      if (worker$pending == 0L && quiet) {
        worker_close(worker)
      }
    },
    delay = idle + 1
  )
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
    settle <- function(value) {
      if (!settled) {
        settled <<- TRUE
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

    later::later(
      function() {
        if (settled) {
          return()
        }
        timed_out <<- TRUE
        try(rs$interrupt(), silent = TRUE)
        later::later(
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
            poll()
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
            poll()
          }
        },
        readfds = fd
      )
    }
    poll()
  })
}

# --- worker side -------------------------------------------------------------
# Everything below runs inside the callr worker process, whose closure
# environment is reset to the global env, so these reference only base R,
# `pkg::fn`, and their own arguments — no commons internals.

worker_init <- function(
  parent_tmp,
  work_dir,
  dll_path,
  network = "none",
  protection = "sandbox",
  sandbox_mode = "auto"
) {
  setwd(work_dir)
  options(width = 80, cli.num_colors = 1)
  worker_lib <- file.path(work_dir, "library")
  dir.create(worker_lib)
  .libPaths(c(worker_lib, .libPaths()))
  if (!protection %in% c("sandbox", "guardrails")) {
    stop("unknown run_r protection mode: ", protection)
  }
  if (identical(protection, "guardrails")) {
    requireNamespace("bit64", quietly = TRUE)
    return(invisible(TRUE))
  }
  sysname <- Sys.info()[["sysname"]]
  if (!sysname %in% c("Linux", "Darwin")) {
    stop(
      "commons cannot sandbox the run_r session on ",
      sysname,
      "; only Linux and macOS are supported."
    )
  }
  if (is.na(dll_path)) {
    stop(
      "commons cannot sandbox the run_r session: its compiled library was ",
      "not found. Install commons as a package, or bundle its src/ directory ",
      "so load_all() can compile it."
    )
  }
  if (!("commons" %in% names(getLoadedDLLs()))) {
    dyn.load(dll_path)
  }
  resolve <- function(paths) {
    vapply(
      paths,
      function(p) tryCatch(normalizePath(p), error = function(e) p),
      character(1),
      USE.NAMES = FALSE
    )
  }
  # The sandboxes match symlink-free paths: Connect's packrat library is a
  # farm of symlinks into a shared cache, and macOS's /tmp and /var live
  # under /private, so grant resolved paths alongside the originals.
  pkg_dirs <- list.dirs(.libPaths(), recursive = FALSE)
  os_roots <- switch(
    sysname,
    Linux = c(
      "/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt/R"
    ),
    Darwin = c(
      "/usr", "/bin", "/sbin", "/System", "/Library",
      "/private/etc", "/private/var/db", "/opt", "/dev"
    )
  )
  read_roots <- unique(c(
    R.home(),
    .libPaths(),
    resolve(pkg_dirs),
    os_roots
  ))
  read_roots <- read_roots[dir.exists(read_roots)]
  read_roots <- unique(c(read_roots, resolve(read_roots)))
  # callr writes its per-call result files into the parent's tempdir, so the
  # worker must be able to write there for results to make it back.
  write_roots <- c(parent_tmp, work_dir)
  write_roots <- unique(c(write_roots, resolve(write_roots)))
  # callr reports status on fd 3 and saves stdout/stderr while a call runs.
  callr_data <- as.environment("tools:callr")[["__callr_data__"]]
  preserve_fds <- c(
    3L,
    callr_data[[".__stdout__"]],
    callr_data[[".__stderr__"]]
  )
  .Call(
    getNativeSymbolInfo("c_sandbox_engage", PACKAGE = "commons"),
    read_roots,
    write_roots,
    # 8 GiB leaves ample headroom for light R; a lower Connect limit still applies.
    8 * 1024^3,
    sandbox_mode,
    preserve_fds,
    network
  )
  # Register methods for integer64 columns transferred from ODBC results.
  requireNamespace("bit64", quietly = TRUE)
  invisible(TRUE)
}

# Define measure/helper sources in the worker's global env so the model can
# read them. Parsing with keep.source here (the worker is non-interactive, so
# it defaults off) keeps comments when a function is printed.
worker_define_functions <- function(fn_sources) {
  for (nm in names(fn_sources)) {
    fn <- eval(
      parse(text = fn_sources[[nm]], keep.source = TRUE),
      envir = globalenv()
    )
    assign(nm, fn, envir = globalenv())
  }
  invisible(TRUE)
}

worker_run_code <- function(
  code,
  new_handles,
  plot_width,
  plot_height
) {
  for (id in names(new_handles)) {
    assign(id, new_handles[[id]], envir = globalenv())
  }

  segments <- list()
  add <- function(type, ...) {
    segments[[length(segments) + 1L]] <<- list(type = type, ...)
  }

  # evaluate emits a recordedplot per plot-modifying step; only flush the
  # prior state when the new one doesn't build on it (btw's run_r prior art).
  is_prefix <- function(x, y) {
    x <- x[[1]]
    y <- y[[1]]
    length(x) <= length(y) && identical(x[], y[seq_along(x)])
  }

  last_plot <- NULL
  flush_plot <- function() {
    if (is.null(last_plot)) {
      return()
    }
    path <- tempfile("plot-", fileext = ".png")
    if (requireNamespace("ragg", quietly = TRUE)) {
      ragg::agg_png(path, width = plot_width, height = plot_height, scaling = 1.5)
    } else {
      grDevices::png(path, width = plot_width, height = plot_height)
    }
    tryCatch(
      grDevices::replayPlot(last_plot),
      finally = grDevices::dev.off()
    )
    add("plot", path = path)
    last_plot <<- NULL
  }

  handler <- evaluate::new_output_handler(
    source = function(src, expr) {
      add("source", text = sub("\n$", "", src$src))
    },
    text = function(text) {
      flush_plot()
      add("text", text = text)
      text
    },
    graphics = function(plot) {
      if (!is.null(last_plot) && !is_prefix(last_plot, plot)) {
        flush_plot()
      }
      last_plot <<- plot
      plot
    },
    message = function(msg) {
      flush_plot()
      add("message", text = sub("\n$", "", conditionMessage(msg)))
      msg
    },
    warning = function(warn) {
      flush_plot()
      add("warning", text = conditionMessage(warn))
      warn
    },
    error = function(err) {
      flush_plot()
      add("error", text = conditionMessage(err))
      err
    },
    value = function(value, visible) {
      if (visible) {
        flush_plot()
        lines <- utils::capture.output(print(value))
        if (length(lines) > 100) {
          lines <- c(
            lines[1:100],
            sprintf("... (%d more lines not shown)", length(lines) - 100)
          )
        }
        # Printing invisibly (e.g. a ggplot, which draws to the device and
        # returns nothing) yields no lines; skip the otherwise-empty segment.
        if (length(lines)) {
          add("text", text = paste(lines, collapse = "\n"))
        }
      }
    }
  )

  guardrails <- if ("commons:guardrails" %in% search()) {
    get(
      ".commons_guardrails",
      envir = as.environment("commons:guardrails"),
      inherits = FALSE
    )
  }
  if (!is.null(guardrails)) {
    restore <- list()
    on.exit({
      for (item in rev(restore)) {
        if (bindingIsLocked(item$name, item$environment)) {
          unlockBinding(item$name, item$environment)
        }
        assign(item$name, item$original, envir = item$environment)
        if (item$locked) {
          lockBinding(item$name, item$environment)
        }
      }
    }, add = TRUE)
    for (hook in guardrails) {
      namespace <- asNamespace(hook$package)
      environments <- list(namespace)
      attached_name <- paste0("package:", hook$package)
      # Attached exports are copied bindings rather than namespace lookups.
      if (attached_name %in% search()) {
        attached <- as.environment(attached_name)
        if (!identical(attached, namespace) &&
          exists(hook$name, envir = attached, inherits = FALSE)) {
          environments <- c(environments, list(attached))
        }
      }
      for (environment in environments) {
        original <- get(hook$name, envir = environment, inherits = FALSE)
        locked <- bindingIsLocked(hook$name, environment)
        if (locked) {
          unlockBinding(hook$name, environment)
        }
        assign(hook$name, hook$replacement, envir = environment)
        if (locked) {
          lockBinding(hook$name, environment)
        }
        restore[[length(restore) + 1L]] <- list(
          name = hook$name,
          environment = environment,
          original = original,
          locked = locked
        )
      }
    }
  }

  evaluate::evaluate(
    code,
    envir = globalenv(),
    stop_on_error = 1,
    new_device = TRUE,
    output_handler = handler
  )
  flush_plot()

  list(segments = segments)
}
