#' Shiny chat app for a commons agent
#'
#' `commons_app()` composes [commons_server()] and [commons_theme()] into a
#' complete app for local development. To customize and deploy the Shiny app, 
#' assemble the UI and server yourself with [commons_theme()] and 
#' [commons_server()].
#'
#' @param client A [commons()] agent.
#' @param ... Extra arguments passed to [shiny::shinyApp()].
#'
#' @return A [shiny::shinyApp()] object.
#'
#' @section Citations and provenance:
#' The server verifies citations against trusted calculations, context, and data
#' documentation as the answer streams. Verified citations appear inline, with
#' details that name the trusted source. A provenance marker follows the answer
#' when it was produced by a trusted calculation, or when a fallback answer
#' cites nothing verified.
#'
#' @examples
#' \dontrun{
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = data_source(sales = sales)
#' )
#' commons_app(agent)
#' }
#'
#' @export
commons_app <- function(client, ...) {
  check_chat_packages()
  check_commons_client(client)

  ui <- function(req) {
    shinychat::page_chat(
      "commons",
      id = "chat",
      theme = commons_theme(),
      toolbar_global = if (rlang::is_interactive()) {
        bslib::toolbar(
          bslib::input_dark_mode(),
          shiny::actionButton("close_btn", label = "", class = "btn-close")
        )
      }
    )
  }

  server <- function(input, output, session) {
    if (rlang::is_interactive()) {
      shiny::setBookmarkExclude("close_btn")
      shiny::observeEvent(input$close_btn, label = "on_close_btn", {
        shiny::stopApp()
      })
    }
    commons_server("chat", client)
  }

  shiny::shinyApp(ui, server, ..., enableBookmarking = "url")
}

#' Chat server and theme for custom commons apps
#'
#' These are the building blocks for deploying a commons chat as a Shiny
#' app; for local development, use [commons_app()]. Pair `commons_server()`
#' with [shinychat::page_chat()] or [shinychat::chat_ui()], passing
#' `theme = commons_theme()` so the commons chat assets are on the page.
#'
#' `commons_theme()` bundles the commons chat CSS and JavaScript into an
#' ordinary [bslib::bs_theme()] (via [shinychat::page_chat_theme()]), so it
#' works anywhere a bslib theme does.
#'
#' @param client A [commons()] agent. In a deployed app, create the agent
#'   inside the server function and pass it to `commons_server()` so each
#'   Shiny session gets its own agent state.
#' @param id The ID of the chat element; must match the `id` of the
#'   [shinychat::page_chat()] or [shinychat::chat_ui()] on the page.
#' @param ... In `commons_server()`, arguments passed to
#'   [shinychat::chat_server()]. In `commons_theme()`, named Sass variables
#'   forwarded to [shinychat::page_chat_theme()].
#' @param preset A bslib or Bootswatch preset name.
#'
#' @return `commons_server()` returns the [shinychat::chat_server()] result.
#'   `commons_theme()` returns a [bslib::bs_theme()] object.
#'
#' @examples
#' \dontrun{
#' library(shiny)
#' library(shinychat)
#'
#' ui <- page_chat("Assistant", id = "chat", theme = commons_theme())
#'
#' server <- function(input, output, session) {
#'   # One agent per session, so each user gets their own agent state
#'   agent <- commons(
#'     ellmer::chat_anthropic(),
#'     data_sources = data_source(sales = sales)
#'   )
#'   commons_server("chat", agent)
#' }
#'
#' shinyApp(ui, server)
#' }
#'
#' @name commons_server
#' @export
commons_server <- function(id, client, ...) {
  check_chat_packages()
  check_commons_client(client)
  local_commons_span(
    "commons_server_start",
    attributes = list("commons.server.id" = id)
  )

  prewarm_on_idle(client)

  chat <- shinychat::chat_server(id, client = client, ...)
  # shinychat owns the conversation identity (it sets the client's
  # `conversation_id` binding, which ellmer stamps on its spans); commons
  # only needs to know that a restore happened.
  chat$history$on_restore(function(values) {
    client$queue_restore_reminder()
  })
  chat
}

#' Pre-warm a commons agent's caches ahead of deployment
#'
#' A [commons()] agent does some expensive setup the first time it needs to:
#' building the search index over the context layer and downloading any
#' uncached pins (see [data_source()]). When you serve the agent with
#' [commons_server()] or [commons_app()], this warming already happens
#' automatically during post-startup idle time, so the first question is
#' (hopefully) fast — you (hopefully) don't need to call 
#' `commons_prewarm()` yourself.
#'
#' The reason to call it directly is to warm the caches *without* running
#' the app. Both kinds of setup are cached on disk — the context index is
#' built once per version of your context documents, and pins are
#' downloaded once into the local pins cache — so running
#' `commons_prewarm(agent, cache_dir)` in a script before deploying lets
#' the deployed app start warm.
#'
#' Pre-warming is a pure optimization — anything it builds is rebuilt on
#' demand if it's missing — so failures are reported as warnings rather
#' than errors. If a pre-deploy script should fail the deploy when warming
#' fails, call the agent's `prewarm()` method directly instead; it lets
#' errors propagate.
#'
#' @section Cache configuration:
#' You can usually ignore this section: by default the context index cache
#' lives in a per-user directory that does the right thing locally and on
#' most hosted platforms. The reasons to configure it are:
#'
#' * **Persistence across deployments on ephemeral hosts.** This is
#'   already handled on Connect and Shiny Server: the cache automatically
#'   lands in Connect's persistent data directory when the server provides
#'   one (currently an early-access feature the administrator enables), or
#'   in an `app_cache/` directory beside the app, which survives
#'   redeploys. But on hosts where no local disk persists (e.g. Connect
#'   Cloud, which resets disk to the deployed bundle and never sets a data
#'   directory), the cache is rebuilt after every redeploy unless you
#'   point it at persistent storage yourself.
#' * **Shipping a warm cache with the app.** Run
#'   `commons_prewarm(agent, cache_dir = "path/inside/the/app")` before
#'   deploying, and the deployed bundle includes the pre-built index.
#'   `cache_dir` is required for this reason — anything resolved
#'   implicitly (a per-user cache directory) would not ship with the
#'   deployment.
#' * **Development loops.** If you're editing context documents and want
#'   each change re-indexed from scratch, disable persistence with
#'   `options(commons.context_cache = FALSE)`.
#'
#' Set the directory with `options(commons.context_cache = "path/to/dir")`
#' or the `COMMONS_CONTEXT_CACHE` environment variable. The cache is
#' capped at 256 MB with least-recently-used eviction; raise
#' `options(commons.context_cache_max_size)` (in bytes) if you index very
#' large context.
#'
#' @param client A [commons()] agent.
#' @param cache_dir A directory for the context index cache, used for this
#'   call only (equivalent to setting
#'   `options(commons.context_cache = cache_dir)` around it). Point it at
#'   a directory inside the app so the warmed index ships with the
#'   deployment. Note that rsconnect excludes `app_cache/` from deployed
#'   bundles, so pick another name.
#'
#' @return `NULL`, invisibly.
#'
#' @examples
#' \dontrun{
#' # In a pre-deploy script: warm the caches into a directory inside the
#' # app, so the deployed bundle includes the pre-built context index
#' agent <- commons(
#'   ellmer::chat_anthropic(),
#'   data_sources = data_source(sales = sales)
#' )
#' # (not app_cache/, which rsconnect excludes from the bundle)
#' commons_prewarm(agent, cache_dir = "commons-cache")
#' }
#'
#' @export
commons_prewarm <- function(client, cache_dir) {
  check_commons_client(client)
  if (missing(cache_dir)) {
    cli::cli_abort(c(
      "{.arg cache_dir} is required.",
      i = "Point it at a directory inside the app (e.g. {.code \"commons-cache\"}) so the warmed cache ships with the deployment."
    ))
  }
  if (!rlang::is_string(cache_dir)) {
    cli::cli_abort("{.arg cache_dir} must be a path to a cache directory.")
  }
  tryCatch(
    {
      withr::with_options(list(commons.context_cache = cache_dir), {
        client$prewarm()
        prewarm_cache_hint(cache_dir)
      })
    },
    error = function(err) {
      msg <- conditionMessage(err)
      cli::cli_warn("{msg}")
    }
  )
  invisible(NULL)
}

# An error escaping a later::later() callback would stop the app, so
# downgrade failures to warnings.
prewarm_on_idle <- function(client) {
  later::later(function() {
    tryCatch(
      client$prewarm(),
      error = function(err) {
        msg <- conditionMessage(err)
        cli::cli_warn("{msg}")
      }
    )
  })
  invisible(NULL)
}

prewarm_cache_hint <- function(cache_dir) {
  store_dir <- context_store_dir(cache_dir)
  if (!dir.exists(store_dir)) {
    cli::cli_warn(c(
      "No context index was cached at {.path {cache_dir}}.",
      i = "The agent has no context layer to index, so the deployed app has nothing to reuse."
    ))
    return(invisible())
  }
  cli::cli_inform(c(
    "Warmed the context index cache at {.path {store_dir}}.",
    i = "To reuse it, deploy the directory with the app and set {.code options(commons.context_cache = \"{cache_dir}\")} in the app, or the {.envvar COMMONS_CONTEXT_CACHE} environment variable on the server."
  ))
  invisible()
}

check_chat_packages <- function(call = rlang::caller_env()) {
  missing <- c("htmltools", "shiny", "shinychat")[
    !vapply(
      c("htmltools", "shiny", "shinychat"),
      requireNamespace,
      logical(1),
      quietly = TRUE
    )
  ]

  if (length(missing)) {
    cli::cli_abort(
      c(
        "The {.pkg commons} chat module requires missing package{?s}: {.pkg {missing}}.",
        i = "Install {.pkg {missing}} to use the {.pkg commons} chat functions."
      ),
      call = call
    )
  }
}

check_commons_client <- function(client, call = rlang::caller_env()) {
  if (!inherits(client, "Commons")) {
    cli::cli_abort(
      "{.arg client} must be an agent created by {.fn commons}.",
      call = call
    )
  }
}

# Asset mtimes ride in the version so the dependency URL changes whenever
# the files do; browsers otherwise cache edited assets under the stable
# version's URL indefinitely.
commons_chat_dependency <- function() {
  src <- system.file("www", "commons-chat", package = "commons")
  stamp <- max(file.mtime(list.files(src, full.names = TRUE, recursive = TRUE)))

  htmltools::htmlDependency(
    name = "commons-chat",
    version = paste0("0.0.0.9000.", as.integer(stamp)),
    src = c(file = src),
    script = "commons-chat.js",
    stylesheet = "commons-chat.css",
    all_files = TRUE
  )
}
