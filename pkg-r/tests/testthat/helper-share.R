json_response <- function(req, body, status = 200L) {
  httr2::new_response(
    req$method %||% "GET",
    req$url,
    status,
    headers = list(`Content-Type` = "application/json"),
    body = charToRaw(jsonlite::toJSON(body, auto_unbox = TRUE))
  )
}

# A Posit Connect server held in memory, for driving share_server() through
# its HTTP requests. `fail` maps "METHOD /path" to a response status (or
# "session" for an expired session token) so a test can make one call fail.
local_fake_connect <- function(env = parent.frame()) {
  withr::local_envvar(
    POSIT_PRODUCT = "CONNECT",
    CONNECT_CONTENT_GUID = "app",
    CONNECT_SERVER = "https://connect.example.com",
    CONNECT_API_KEY = "owner-key",
    .local_envir = env
  )
  rm(list = ls(share_cache), envir = share_cache)
  withr::defer(rm(list = ls(share_cache), envir = share_cache), envir = env)

  connect <- new.env(parent = emptyenv())
  connect$requests <- character()
  connect$fail <- list()
  connect$users <- list(
    ada = list(guid = "ada", username = "ada", first_name = "Ada", last_name = "Lovelace", email = "ada@example.com", user_role = "publisher"),
    bob = list(guid = "bob", username = "bob", first_name = "Bob", last_name = "", email = "bob@example.com", user_role = "viewer"),
    olive = list(guid = "olive", username = "olive", first_name = "Olive", last_name = "", email = "olive@example.com", user_role = "publisher")
  )
  connect$content <- list(app = list(
    guid = "app",
    title = "Bird explorer",
    content_url = "https://connect.example.com/birds/",
    access_type = "acl",
    owner_guid = "olive"
  ))
  connect$permissions <- list(
    app = list(list(id = "app-p1", principal_guid = "bob", principal_type = "user"))
  )
  connect$n <- list()
  connect$integrations <- list(
    list(guid = "publisher", template = "connect", auth_type = "Visitor API Key", config = list(max_role = "Publisher"))
  )
  connect$associations <- list("publisher")

  httr2::local_mocked_responses(function(req) fake_connect_respond(connect, req), env = env)
  connect
}

fake_connect_respond <- function(connect, req) {
  method <- httr2::req_get_method(req)
  path <- sub("^/__api__/v1/", "", httr2::url_parse(req$url)$path)
  key <- paste(method, path)
  connect$requests <- c(connect$requests, key)
  fail <- connect$fail[[key]]
  if (identical(fail, "session")) {
    return(json_response(req, list(code = 0, error = "expired", error_code = 215L), 400L))
  }
  if (!is.null(fail)) {
    return(json_response(req, list(error = "boom"), fail))
  }
  parts <- strsplit(path, "/", fixed = TRUE)[[1]]
  body <- if (method %in% c("POST", "PATCH") && !is.null(req$body$data) && is.list(req$body$data)) req$body$data
  next_id <- function(prefix) {
    connect$n[[prefix]] <- (connect$n[[prefix]] %||% 0L) + 1L
    paste0(prefix, connect$n[[prefix]])
  }

  if (path == "content/app/oauth/integrations/associations") {
    if (method == "PUT") {
      connect$associations <- vapply(req$body$data, function(x) x$oauth_integration_guid, "")
      return(httr2::new_response("PUT", req$url, 204L, headers = list(), body = raw()))
    }
    integrations <- Filter(function(x) x$guid %in% connect$associations, connect$integrations)
    return(json_response(req, lapply(integrations, function(x) list(
      oauth_integration_guid = x$guid,
      oauth_integration_template = x$template,
      oauth_integration_auth_type = x$auth_type
    ))))
  }
  if (path == "oauth/integrations") {
    return(json_response(req, connect$integrations))
  }
  if (parts[1] == "oauth" && parts[2] == "integrations" && length(parts) == 3 && parts[3] != "credentials") {
    integration <- Filter(function(x) x$guid == parts[3], connect$integrations)[[1]]
    return(json_response(req, integration))
  }
  if (path == "oauth/integrations/credentials") {
    return(json_response(req, list(access_token = "visitor-key")))
  }
  if (path == "user") {
    return(json_response(req, connect$users$ada))
  }
  if (parts[1] == "users" && length(parts) == 2) {
    return(json_response(req, connect$users[[parts[2]]]))
  }
  if (parts[1] == "tasks") {
    return(json_response(req, list(finished = TRUE, code = 0L)))
  }
  if (path == "content" && method == "POST") {
    guid <- next_id("copy")
    connect$content[[guid]] <- list(
      guid = guid,
      title = body$title,
      content_url = paste0("https://connect.example.com/content/", guid, "/"),
      dashboard_url = paste0("https://connect.example.com/connect/#/apps/", guid),
      access_type = "acl",
      owner_guid = "ada"
    )
    connect$permissions[[guid]] <- list()
    return(json_response(req, connect$content[[guid]]))
  }
  if (parts[1] != "content") {
    return(json_response(req, list(error = "not found"), 404L))
  }

  guid <- parts[2]
  content <- connect$content[[guid]]
  if (is.null(content)) {
    return(json_response(req, list(error = "not found"), 404L))
  }
  if (length(parts) == 2) {
    if (method == "DELETE") {
      connect$content[[guid]] <- NULL
      return(httr2::new_response("DELETE", req$url, 204L, headers = list(), body = raw()))
    }
    if (method == "PATCH") {
      connect$content[[guid]]$access_type <- body$access_type
    }
    return(json_response(req, connect$content[[guid]]))
  }
  switch(
    parts[3],
    bundles = json_response(req, list(id = next_id("bundle"))),
    deploy = json_response(req, list(task_id = next_id("task"))),
    permissions = {
      if (method == "POST") {
        permission <- list(
          id = next_id("p"),
          principal_guid = body$principal_guid,
          principal_type = body$principal_type
        )
        connect$permissions[[guid]] <- c(connect$permissions[[guid]], list(permission))
        json_response(req, permission)
      } else if (method == "DELETE") {
        connect$permissions[[guid]] <- Filter(
          function(p) !identical(p$id, parts[4]),
          connect$permissions[[guid]]
        )
        httr2::new_response("DELETE", req$url, 204L, headers = list(), body = raw())
      } else {
        json_response(req, connect$permissions[[guid]])
      }
    }
  )
}

# Who can open a copy, by principal guid.
fake_connect_viewers <- function(connect, guid) {
  sort(vapply(connect$permissions[[guid]], `[[`, character(1), "principal_guid"))
}

# A MockShinySession that arrives with a Connect session token and keeps the
# dialogs and inserted UI it is sent.
ShareSession <- R6::R6Class(
  "ShareSession",
  inherit = shiny::MockShinySession,
  # Match the parent class, which isn't portable, adds its no-op methods to
  # each instance, and finds shiny's internals from where a subclass is defined.
  portable = FALSE,
  lock_objects = FALSE,
  parent_env = new.env(parent = asNamespace("shiny")),
  public = list(
    modals = list(),
    inserts = list(),
    removes = character(),
    reconnect = NULL,
    initialize = function() {
      super$initialize()
      unlockBinding("allowReconnect", self)
      self$allowReconnect <- function(value) {
        reconnect <<- value
        invisible()
      }
      unlockBinding("sendModal", self)
      self$sendModal <- function(type, message) {
        html <- as.character(message$html %||% "")
        modals <<- c(modals, list(list(type = type, html = html)))
        invisible()
      }
      unlockBinding("sendInsertUI", self)
      self$sendInsertUI <- function(selector, multiple, where, content) {
        inserts <<- c(inserts, list(list(selector = selector, html = content$html)))
        invisible()
      }
      unlockBinding("sendRemoveUI", self)
      self$sendRemoveUI <- function(selector, multiple) {
        removes <<- c(removes, selector)
        invisible()
      }
    }
  ),
  active = list(
    request = function(value) list(HTTP_POSIT_CONNECT_USER_SESSION_TOKEN = "session-token")
  )
)

# A conversation whose one run_sql result can be shared, and the chat that
# saves its receipts.
share_test_chat <- function() {
  agent <- test_agent()
  req <- ellmer::ContentToolRequest(
    id = "q1",
    name = "run_sql",
    arguments = list(sql = "SELECT region FROM sales")
  )
  result <- run_sql_tool(test_source(), "SELECT region FROM sales")
  result@request <- req
  agent$set_turns(list(
    ellmer::UserTurn(list(ellmer::ContentText("Which regions?"))),
    ellmer::AssistantTurn(list(req)),
    ellmer::UserTurn(list(result))
  ))
  markdown <- result@extra$display$markdown

  hooks <- new.env()
  hooks$saves <- 0L
  chat <- list(
    status = function() "idle",
    history = list(
      conversation_id = function() "conversation",
      on_restore = function(fn) hooks$restore <- fn,
      on_save = function(fn) hooks$save <- fn,
      save = function() hooks$saves <- hooks$saves + 1L
    )
  )
  output_id <- regmatches(markdown, regexpr("[0-9a-f]{16}", markdown))
  list(
    agent = agent,
    chat = chat,
    hooks = hooks,
    output_id = output_id,
    receipt = function() {
      hooks$save(list())$commons_shares[[paste0("output:", output_id)]]
    }
  )
}

# Runs pending promises and the reactive flushes they cause.
settle <- function(session) {
  for (i in 1:100) {
    later::run_now(0.01, all = TRUE)
    session$flushReact()
    if (later::loop_empty()) {
      later::run_now(0.01, all = TRUE)
      session$flushReact()
      if (later::loop_empty()) break
    }
  }
}

share_test_app <- function(s) {
  function(input, output, session) share_server("chat", s$agent, s$chat, session)
}

open_output_share <- function(session, s, nonce = 1) {
  session$setInputs(chat_share_output = list(id = s$output_id, nonce = nonce))
  settle(session)
}
