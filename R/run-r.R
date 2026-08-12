tool_run_r <- function(private) {
  handle_tools <- c(
    if (length(private$registry) > 0) "call_measure",
    if (registry_has_metrics(private$definitions)) "call_metrics",
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
      "Run R code in your sandboxed R session to analyze results or render plots.",
      "R code and textual output are visible only to you; rendered plots are",
      "also shown to the user.",
      "The user cannot run code in this session themselves.",
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
      "\n- Create at most one figure per call and return it implicitly rather",
      "than saving it.",
      "\n- Do not use this tool to talk to the user; explanations belong in your reply.",
      "\n- Return results implicitly (`x`, not `print(x)`) and prefer brief",
      "summaries (head(), summary()) over large outputs.",
      if (identical(private$worker$network, "none")) {
        "\n- The session has no network access."
      },
      "\n- The session can only write to its own temporary directory."
    ),
    arguments = list(
      code = ellmer::type_string("The R code to run.")
    ),
    name = "run_r",
    annotations = ellmer::tool_annotations(
      title = "R code",
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
        dims <- plot_dimensions(
          getOption("commons.run_r_plot_aspect_ratio", "3:2"),
          getOption("commons.run_r_plot_size", 768L)
        )
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
      title = "Ran R code",
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
    title = "Ran R code",
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
  details_html <- sprintf(
    "<details class=\"commons-run-r-details\"><summary>Details</summary><pre><code class=\"language-r\">%s</code></pre></details>",
    html_escape(paste(c(code, output), collapse = "\n"))
  )
  sprintf(
    "<div class=\"commons-run-r-display\">%s</div>",
    paste(c(details_html, plot_html), collapse = "\n")
  )
}

# --- worker lifecycle --------------------------------------------------------

new_r_worker <- function(
  network = "none",
  sandbox_mode = run_r_sandbox_mode()
) {
  sandbox_mode <- rlang::arg_match(
    sandbox_mode,
    c("auto", "landlock", "userns", "nsjail")
  )
  worker <- new.env(parent = emptyenv())
  worker$network <- network
  worker$sandbox_mode <- sandbox_mode
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
  parent_tmp <- tempdir()
  options <- worker_session_options(
    work_dir,
    parent_tmp,
    worker$network,
    worker$sandbox_mode
  )
  if (identical(worker$sandbox_mode, "nsjail")) {
    nsjail_log(
      "starting callr worker: network=%s work_dir=%s",
      worker$network,
      work_dir
    )
  }
  rs <- callr::r_session$new(
    options,
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
      parent_tmp = parent_tmp,
      work_dir = work_dir,
      dll_path = commons_dll_path(),
      network = worker$network,
      sandbox_mode = worker$sandbox_mode,
      sandboxed_by_nsjail = identical(worker$sandbox_mode, "nsjail")
    )
  )
  # Defining sources at spawn (rather than syncing per call like handles)
  # means a respawned worker gets them again for free.
  if (length(fn_sources)) {
    rs$run(worker_define_functions, args = list(fn_sources = fn_sources))
  }
  if (identical(worker$sandbox_mode, "nsjail")) {
    nsjail_log("callr worker initialized")
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

nsjail_path <- function() {
  path <- getOption("commons.nsjail_path", Sys.which("nsjail"))
  if (!is.character(path) || length(path) != 1 || is.na(path)) {
    return("")
  }
  path
}

worker_session_options <- function(
  work_dir,
  parent_tmp,
  network,
  sandbox_mode
) {
  env <- worker_scrubbed_env(
    work_dir,
    worker_single_thread(sandbox_mode)
  )
  options <- callr::r_session_options(env = env)
  if (!identical(sandbox_mode, "nsjail")) {
    return(options)
  }

  spec <- nsjail_worker_spec(work_dir, parent_tmp, network, env)
  callr::r_session_options(env = env, arch = spec$wrapper)
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

nsjail_quote <- function(x) {
  if (!is.character(x) || length(x) != 1 || is.na(x) ||
      grepl("[[:cntrl:]]", x)) {
    cli::cli_abort("nsjail configuration values must be one-line strings.")
  }
  x <- gsub("\\", "\\\\", x, fixed = TRUE)
  x <- gsub("\"", "\\\"", x, fixed = TRUE)
  paste0("\"", x, "\"")
}

worker_sandbox_roots <- function(parent_tmp, work_dir, sysname) {
  resolve <- function(paths) {
    vapply(
      paths,
      function(p) tryCatch(normalizePath(p), error = function(e) p),
      character(1),
      USE.NAMES = FALSE
    )
  }
  pkg_dirs <- list.dirs(.libPaths(), recursive = FALSE)
  os_roots <- switch(
    sysname,
    Linux = c("/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt/R"),
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
  write_roots <- c(parent_tmp, work_dir)
  write_roots <- unique(c(write_roots, resolve(write_roots)))
  list(read = read_roots, write = write_roots)
}

nsjail_seccomp <- function(network) {
  namespace_flags <- paste(
    c(
      "0x10000000", "0x00020000", "0x40000000", "0x20000000",
      "0x08000000", "0x04000000", "0x02000000"
    ),
    collapse = " | "
  )
  denied <- c(
    "ptrace",
    "process_vm_readv",
    "process_vm_writev",
    "mount",
    "pivot_root",
    "chroot",
    "unshare",
    "setns",
    "open_tree",
    "move_mount",
    "fsopen",
    "fsconfig",
    "fsmount",
    "fspick",
    "mount_setattr"
  )
  if (identical(network, "none")) {
    denied <- c(denied, "socket", "io_uring_setup")
  }
  unmount <- c(
    "SYSCALL[166] ON x86_64",
    "SYSCALL[39] ON aarch64",
    "SYSCALL[52] ON { x86, arm }"
  )
  c(
    "POLICY commons {",
    paste0(
      "  ERRNO(1) { ",
      paste(c(denied, unmount), collapse = ", "),
      ","
    ),
    paste0("    clone { (clone_flags & (", namespace_flags, ")) != 0 }"),
    "  },",
    "  ERRNO(38) { clone3 }",
    "}",
    "USE commons DEFAULT ALLOW"
  )
}

nsjail_worker_spec <- function(work_dir, parent_tmp, network, env) {
  network <- rlang::arg_match(network, c("none", "full"))
  if (!identical(Sys.info()[["sysname"]], "Linux")) {
    cli::cli_abort("{.code nsjail} is only supported on Linux.")
  }
  nsjail <- nsjail_path()
  if (!nzchar(nsjail) || file.access(nsjail, mode = 1) != 0) {
    cli::cli_abort(
      "commons cannot sandbox the {.code run_r} session because {.code nsjail}
       is not installed or is not executable."
    )
  }

  roots <- worker_sandbox_roots(parent_tmp, work_dir, "Linux")
  nsjail_log(
    "building policy: binary=%s network=%s read_roots=%d write_roots=%d",
    nsjail,
    network,
    length(roots$read),
    length(roots$write)
  )
  mount <- function(path, rw) {
    c(
      "mount {",
      paste0("  src: ", nsjail_quote(path)),
      paste0("  dst: ", nsjail_quote(path)),
      "  is_bind: true",
      paste0("  rw: ", tolower(as.character(rw))),
      "  mandatory: true",
      "}"
    )
  }
  env_values <- env[!is.na(env)]
  inherited <- Sys.getenv(
    c(
      "PATH", "LANG", "LD_LIBRARY_PATH", "R_HOME", "R_LIBS", "R_LIBS_USER",
      "R_LIBS_SITE", "R_ENVIRON", "R_ENVIRON_USER", "R_PROFILE",
      "R_PROFILE_USER", names(Sys.getenv())[startsWith(names(Sys.getenv()), "LC_")]
    ),
    unset = NA_character_
  )
  inherited <- inherited[!is.na(inherited)]
  child_env <- c(inherited, env_values)
  child_env <- child_env[!duplicated(names(child_env), fromLast = TRUE)]
  config <- c(
    "name: \"commons-run-r\"",
    "mode: EXECVE",
    paste0("cwd: ", nsjail_quote(work_dir)),
    "time_limit: 0",
    "disable_rl: true",
    "keep_env: false",
    "clone_newuser: true",
    "clone_newns: true",
    paste0("clone_newnet: ", tolower(as.character(identical(network, "none")))),
    "clone_newpid: false",
    "clone_newipc: false",
    "clone_newuts: false",
    "clone_newcgroup: false",
    "uidmap { inside_id: \"0\" outside_id: \"\" count: 1 }",
    "gidmap { inside_id: \"0\" outside_id: \"\" count: 1 }",
    # callr uses fd 3 for its control protocol and redirects output to fds 5
    # and 6 while a request is running. nsjail otherwise retains only stdio.
    "pass_fd: 3",
    "pass_fd: 5",
    "pass_fd: 6",
    unlist(lapply(roots$read, mount, rw = FALSE), use.names = FALSE),
    unlist(lapply(roots$write, mount, rw = TRUE), use.names = FALSE),
    paste0(
      "envar: ",
      vapply(
        paste0(names(child_env), "=", unname(child_env)),
        nsjail_quote,
        character(1)
      )
    ),
    paste0("seccomp_string: ", vapply(nsjail_seccomp(network), nsjail_quote, character(1)))
  )
  config_path <- file.path(work_dir, ".commons-nsjail.cfg")
  wrapper_path <- file.path(work_dir, ".commons-nsjail")
  writeLines(config, config_path, useBytes = TRUE)
  writeLines(
    c(
      "#!/bin/sh",
      paste(
        "exec",
        shQuote(nsjail),
        "--config",
        shQuote(config_path),
        "--",
        shQuote(normalizePath(file.path(R.home("bin"), "R"))),
        "\"$@\""
      )
    ),
    wrapper_path,
    useBytes = TRUE
  )
  Sys.chmod(wrapper_path, mode = "0755")
  nsjail_log(
    "launch configuration written: config=%s wrapper=%s",
    config_path,
    wrapper_path
  )
  list(config = config_path, wrapper = wrapper_path)
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

plot_dimensions <- function(ratio, longest_side) {
  parts <- suppressWarnings(
    as.numeric(strsplit(ratio, ":", fixed = TRUE)[[1]])
  )
  r <- if (length(parts) == 2 && all(!is.na(parts) & parts > 0)) {
    parts[[1]] / parts[[2]]
  } else {
    3 / 2
  }
  if (r >= 1) {
    list(width = as.integer(round(longest_side)), height = as.integer(round(longest_side / r)))
  } else {
    list(width = as.integer(round(longest_side * r)), height = as.integer(round(longest_side)))
  }
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
  sandbox_mode = "auto",
  sandboxed_by_nsjail = FALSE
) {
  setwd(work_dir)
  options(width = 80, cli.num_colors = 1)
  # Every platform that runs worker code must engage a sandbox.
  sysname <- Sys.info()[["sysname"]]
  if (!sysname %in% c("Linux", "Darwin")) {
    stop(
      "commons cannot sandbox the run_r session on ",
      sysname,
      "; only Linux and macOS are supported."
    )
  }
  if (is.na(dll_path) && !sandboxed_by_nsjail) {
    stop(
      "commons cannot sandbox the run_r session: its compiled library was ",
      "not found. Install commons as a package, or bundle its src/ directory ",
      "so load_all() can compile it."
    )
  }
  if (!sandboxed_by_nsjail && !("commons" %in% names(getLoadedDLLs()))) {
    dyn.load(dll_path)
  }
  if (!sandboxed_by_nsjail) {
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
    sym <- getNativeSymbolInfo("c_sandbox_engage", PACKAGE = "commons")
    .Call(
      sym,
      read_roots,
      write_roots,
      NULL,
      sandbox_mode,
      preserve_fds,
      network
    )
  }
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

worker_run_code <- function(code, new_handles, plot_width, plot_height) {
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
