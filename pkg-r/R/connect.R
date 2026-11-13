# A minimal Posit Connect API client for the operations commons needs.

is_connect_runtime <- function() {
  identical(Sys.getenv("POSIT_PRODUCT"), "CONNECT") ||
    nzchar(Sys.getenv("CONNECT_CONTENT_GUID"))
}

connect_content_guid <- function() {
  Sys.getenv("CONNECT_CONTENT_GUID")
}

connect_client <- function(
  server = NULL,
  api_key = NULL,
  call = rlang::caller_env()
) {
  server <- server %||% Sys.getenv("CONNECT_SERVER")
  api_key <- api_key %||% Sys.getenv("CONNECT_API_KEY")
  if (!nzchar(server)) {
    cli::cli_abort(
      "Set the {.envvar CONNECT_SERVER} environment variable to your Posit
       Connect server URL.",
      call = call
    )
  }
  if (!nzchar(api_key)) {
    cli::cli_abort(
      "Set the {.envvar CONNECT_API_KEY} environment variable to a Posit
       Connect API key.",
      call = call
    )
  }
  server <- sub("/+(__api__/*)?$", "", server)
  list(server = server, api_key = api_key)
}

connect_req <- function(client, ...) {
  httr2::request(client$server) |>
    httr2::req_url_path_append("__api__", "v1", ...) |>
    httr2::req_headers_redacted(Authorization = paste("Key", client$api_key))
}

connect_server_settings <- function(client) {
  httr2::request(client$server) |>
    httr2::req_url_path_append("__api__", "server_settings") |>
    httr2::req_headers_redacted(
      Authorization = paste("Key", client$api_key)
    ) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
}

# Search exposes vanity URLs to content viewers without requiring the
# administrator-only endpoint that lists every vanity URL on the server.
connect_vanity_guid <- function(
  client,
  url,
  query,
  call = rlang::caller_env()
) {
  page_number <- 1L
  repeat {
    body <- connect_req(client, "search", "content") |>
      httr2::req_url_query(
        q = query,
        include = "vanity_url",
        page_number = page_number,
        page_size = 100
      ) |>
      httr2::req_perform() |>
      httr2::resp_body_json(simplifyVector = TRUE)
    results <- body$results
    if (
      is.data.frame(results) &&
        all(c("guid", "vanity_url") %in% names(results))
    ) {
      expected <- paste0(client$server, "/", sub("^/+", "", query))
      matches <- !is.na(results$vanity_url) &
        normalize_connect_url(results$vanity_url) ==
          normalize_connect_url(expected)
      if (any(matches)) {
        return(results$guid[which(matches)[[1]]])
      }
    }
    if (is.null(body$total) || page_number >= body$total) {
      break
    }
    page_number <- page_number + 1L
  }

  cli::cli_abort(
    c(
      "Can't find content for the Connect vanity URL {.url {url}}.",
      i = "Check that the URL is correct and that your API key can access the
           content."
    ),
    call = call
  )
}

normalize_connect_url <- function(x) {
  x <- sub("[?#].*$", "", x)
  utils::URLdecode(sub("/+$", "", x))
}

# Fetch trace rows for a content item as raw OTLP NDJSON lines, paging until
# the X-Total-Count header is exhausted. On servers with a single trace store,
# `enough(lines)` can stop paging early.
# Connect returns rows newest-first by span start time and filters `from`/`to`
# on span start time over `[from, to)`.
connect_trace_lines <- function(
  client,
  guid,
  from = NULL,
  to = NULL,
  enough = NULL,
  page_size = 1000,
  call = rlang::caller_env()
) {
  lines <- character()
  offset <- 0
  version <- NULL
  repeat {
    resp <- tryCatch(
      connect_req(client, "content", guid, "traces") |>
        httr2::req_url_query(
          limit = page_size,
          offset = offset,
          from = connect_window_param(from, -3600),
          to = connect_window_param(to, 1)
        ) |>
        httr2::req_perform(),
      httr2_http_401 = function(err) trace_access_abort(err, call),
      httr2_http_403 = function(err) trace_access_abort(err, call),
      httr2_http_404 = function(err) NULL
    )
    if (is.null(resp)) {
      return(connect_job_trace_lines(
        client, guid, from, page_size, call
      ))
    }
    version <- version %||% parse_connect_version(
      httr2::resp_header(resp, "Server")
    )
    page <- resp_trace_lines(resp)
    lines <- c(lines, page)
    total <- suppressWarnings(
      as.integer(httr2::resp_header(resp, "X-Total-Count"))
    )
    offset <- offset + length(page)
    if (
      !is.null(version) && version < numeric_version("2026.07.0") &&
        length(lines) > 0 && !is.null(enough) && enough(lines)
    ) {
      return(lines)
    }
    if (length(page) == 0 || is.na(total) || offset >= total) {
      break
    }
  }
  # Connect 2026.07 moved new traces without migrating the per-job files.
  if (is.null(version) || version >= numeric_version("2026.07.0")) {
    lines <- connect_job_trace_lines(
      client, guid, from, page_size, call, lines
    )
  }
  unique(lines)
}

connect_job_trace_lines <- function(
  client,
  guid,
  from,
  page_size,
  call,
  lines = character()
) {
  jobs <- tryCatch(
    connect_req(client, "content", guid, "jobs") |>
      httr2::req_perform() |>
      httr2::resp_body_json(),
    httr2_http_401 = function(err) trace_access_abort(err, call),
    httr2_http_403 = function(err) trace_access_abort(err, call)
  )
  job_keys <- vapply(jobs, function(job) job$key, character(1))
  offsets <- integer(length(job_keys))
  max_active <- 20

  while (length(job_keys) > 0) {
    requests <- vector("list", length(job_keys))
    for (i in seq_along(job_keys)) {
      requests[[i]] <- connect_job_trace_req(
        job_key = job_keys[[i]],
        offset = offsets[[i]],
        client = client,
        guid = guid,
        from = from,
        page_size = page_size,
        max_active = max_active
      )
    }
    responses <- httr2::req_perform_parallel(
      requests,
      on_error = "continue",
      progress = FALSE,
      max_active = max_active
    )
    next_job_keys <- character()
    next_offsets <- integer()

    for (i in seq_along(responses)) {
      resp <- responses[[i]]
      if (inherits(resp, c("httr2_http_401", "httr2_http_403"))) {
        trace_access_abort(resp, call)
      }
      if (inherits(resp, "httr2_http_404")) {
        next
      }
      if (inherits(resp, "condition")) {
        rlang::cnd_signal(resp)
      }
      page <- resp_trace_lines(resp)
      lines <- c(lines, page)
      total <- suppressWarnings(
        as.integer(httr2::resp_header(resp, "X-Total-Count"))
      )
      offset <- offsets[[i]] + length(page)
      if (length(page) > 0 && !is.na(total) && offset < total) {
        next_job_keys <- c(next_job_keys, job_keys[[i]])
        next_offsets <- c(next_offsets, offset)
      }
    }
    job_keys <- next_job_keys
    offsets <- next_offsets
  }
  lines
}

connect_job_trace_req <- function(
  job_key,
  offset,
  client,
  guid,
  from,
  page_size,
  max_active
) {
  connect_req(client, "content", guid, "jobs", job_key, "traces") |>
    httr2::req_url_query(
      limit = page_size,
      offset = offset,
      since = connect_window_param(from, -3600)
    ) |>
    httr2::req_throttle(capacity = max_active, fill_time_s = 0.5)
}

resp_trace_lines <- function(resp) {
  if (!httr2::resp_has_body(resp)) {
    return(character())
  }
  page <- httr2::resp_body_string(resp)
  page <- strsplit(page, "\n", fixed = TRUE)[[1]]
  page[nzchar(page)]
}

parse_connect_version <- function(x) {
  if (!is.character(x) || length(x) != 1 || is.na(x)) {
    return(NULL)
  }
  match <- regexec("([0-9]+(?:\\.[0-9]+){1,2})", x)
  version <- regmatches(x, match)[[1]]
  if (length(version) == 0) {
    return(NULL)
  }
  numeric_version(version[[2]])
}

# Connect silently ignores timestamps it can't parse, including any without
# an explicit timezone, so always format the query bounds here. The exact
# window is applied client-side, so bounds are padded outward: `from` by an
# hour, to keep the earlier-starting parent spans that carry conversation
# ids, and `to` by a second, to cover sub-second truncation in formatting.
connect_window_param <- function(time, pad) {
  if (is.null(time)) {
    return(NULL)
  }
  format(time + pad, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

connect_content <- function(client, guid) {
  connect_req(client, "content", guid) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
}

connect_enable_otel <- function(client, guid) {
  connect_req(client, "content", guid) |>
    httr2::req_method("PATCH") |>
    httr2::req_body_json(list(otel_enabled = TRUE)) |>
    httr2::req_perform()
  invisible(NULL)
}

# An auth failure on the traces endpoint nearly always means the API key's
# user fails the endpoint's editor-level permission check, not that traces
# don't exist; say so rather than surfacing a bare 401/403.
trace_access_abort <- function(err, call) {
  cli::cli_abort(
    c(
      "Couldn't read this content's traces from Posit Connect.",
      i = "Reading traces requires editor access: the {.envvar
           CONNECT_API_KEY} user must own the content or be a collaborator.
           See the {.arg share_with} argument of {.fn commons}."
    ),
    parent = err,
    call = call
  )
}

# Prefix search over users, paging like Connect's own full-listing loop: a
# page shorter than page_size is the last one.
connect_user_guid <- function(client, username, call = rlang::caller_env()) {
  page_size <- 500
  page_number <- 1
  repeat {
    resp <- connect_req(client, "users") |>
      httr2::req_url_query(
        prefix = username,
        page_size = page_size,
        page_number = page_number
      ) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
    for (user in resp$results) {
      if (identical(tolower(user$username), tolower(username))) {
        return(user$guid)
      }
    }
    if (length(resp$results) < page_size) {
      break
    }
    page_number <- page_number + 1
  }
  cli::cli_abort(
    "No Connect user with username {.val {username}}.",
    call = call
  )
}

connect_permission_principals <- function(client, guid) {
  perms <- connect_req(client, "content", guid, "permissions") |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  vapply(perms, function(perm) perm$principal_guid, character(1))
}

# Reading a content item's traces requires editor-level access, which
# Connect's permissions API grants via the "owner" (collaborator) role;
# "editor" is not an accepted role string there.
connect_add_collaborator <- function(client, guid, principal_guid) {
  connect_req(client, "content", guid, "permissions") |>
    httr2::req_body_json(list(
      principal_guid = principal_guid,
      principal_type = "user",
      role = "owner",
      send_email = FALSE
    )) |>
    httr2::req_perform()
  invisible(NULL)
}

# Failures aren't cached, so a later session checks again.
connect_share_audience <- function(before_attach = function() NULL) {
  if (exists("audience", envir = share_cache)) {
    return(share_cache$audience)
  }
  tryCatch(
    share_cache$audience <- connect_visitor_integration(
      connect_client(),
      connect_content_guid(),
      before_attach
    ),
    error = function(err) {
      cli::cli_warn(
        "Couldn't set up this content's integrations, so sharing is off.",
        parent = err
      )
      NULL
    }
  )
}

share_cache <- new.env(parent = emptyenv())

# An integration capped at the Viewer role can't publish. Connect ships a
# suitable integration, but each content item must be associated with it, so
# commons associates one when none is, rather than asking the publisher to.
connect_visitor_integration <- function(client, guid, before_attach = function() NULL) {
  if (!nzchar(guid)) {
    return(NULL)
  }
  associations <- connect_req(
    client, "content", guid, "oauth", "integrations", "associations"
  ) |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  for (association in associations) {
    if (
      !identical(association$oauth_integration_template, "connect") ||
        !identical(association$oauth_integration_auth_type, "Visitor API Key")
    ) {
      next
    }
    integration <- connect_req(
      client, "oauth", "integrations", association$oauth_integration_guid
    ) |>
      httr2::req_perform() |>
      httr2::resp_body_json()
    if (!identical(integration$config$max_role, "Viewer")) {
      return(association$oauth_integration_guid)
    }
  }
  attached <- connect_attach_visitor_integration(client, guid, associations, before_attach)
  if (is.null(attached)) {
    cli::cli_warn(
      "Posit Connect has no Visitor API Key integration that can publish, so sharing is off."
    )
  }
  attached
}

# Associating replaces the content's associations, so the existing ones are
# sent along with the new one. Connect then restarts the content's processes,
# so `before_attach` can prepare the session that triggers it.
connect_attach_visitor_integration <- function(
  client,
  guid,
  associations,
  before_attach = function() NULL
) {
  integrations <- connect_req(client, "oauth", "integrations") |>
    httr2::req_perform() |>
    httr2::resp_body_json()
  candidates <- Filter(
    function(integration) {
      identical(integration$template, "connect") &&
        identical(integration$auth_type, "Visitor API Key") &&
        !is.null(integration$config$max_role) &&
        !identical(integration$config$max_role, "Viewer")
    },
    integrations
  )
  if (length(candidates) == 0) {
    return(NULL)
  }
  # Prefer the least privilege that can still publish.
  roles <- vapply(candidates, function(x) x$config$max_role, character(1))
  chosen <- candidates[[c(which(roles == "Publisher"), 1L)[1]]]

  guids <- c(
    vapply(associations, function(x) x$oauth_integration_guid, character(1)),
    chosen$guid
  )
  before_attach()
  connect_req(client, "content", guid, "oauth", "integrations", "associations") |>
    httr2::req_method("PUT") |>
    httr2::req_body_json(lapply(guids, function(g) list(oauth_integration_guid = g))) |>
    httr2::req_perform()
  chosen$guid
}

# Opens a share as the viewer: their key and identity, and the content the
# copy goes to, which is `guid` when they still own it and new otherwise.
# Creating the content first gives the viewer a link before the deploy.
connect_share_open <- coro::async(function(token, audience, title, guid = NULL) {
  owner <- connect_client()
  key <- await(connect_visitor_key(owner, token, audience))
  visitor <- list(server = owner$server, api_key = key)

  user <- await(connect_json(connect_req(visitor, "user")))
  if (identical(user$user_role, "viewer")) {
    share_abort("role")
  }

  content <- NULL
  if (!is.null(guid)) {
    content <- await(connect_owned_content(visitor, guid, user$guid))
  }
  created <- is.null(content)
  if (created) {
    content <- await(connect_json(
      connect_req(visitor, "content") |>
        httr2::req_body_json(list(title = title))
    ))
  }
  list(visitor = visitor, user = user, content = content, created = created)
})

connect_visitor_role <- coro::async(function(token, audience) {
  owner <- connect_client()
  key <- await(connect_visitor_key(owner, token, audience))
  visitor <- list(server = owner$server, api_key = key)
  user <- await(connect_json(connect_req(visitor, "user")))
  user$user_role
})

connect_share_deploy <- coro::async(function(visitor, guid, archive) {
  bundle <- await(connect_json(
    connect_req(visitor, "content", guid, "bundles") |>
      httr2::req_body_file(archive, type = "application/gzip")
  ))
  deploy <- await(connect_json(
    connect_req(visitor, "content", guid, "deploy") |>
      httr2::req_body_json(list(bundle_id = bundle$id))
  ))
  await(connect_wait_task(visitor, deploy$task_id))
})

# Users and groups whose name starts with `query`, as one list.
connect_search_principals <- function(client, query, limit = 8) {
  users <- connect_json(
    connect_req(client, "users") |>
      httr2::req_url_query(prefix = query, page_size = limit)
  )
  groups <- connect_json(
    connect_req(client, "groups") |>
      httr2::req_url_query(prefix = query, page_size = limit)
  )
  promises::then(promises::promise_all(users = users, groups = groups), function(x) {
    c(
      lapply(x$users$results, connect_user_principal),
      lapply(x$groups$results, connect_group_principal)
    )
  })
}

connect_user_principal <- function(user) {
  name <- trimws(paste(user$first_name %||% "", user$last_name %||% ""))
  list(
    guid = user$guid,
    type = "user",
    name = if (nzchar(name)) name else user$username,
    detail = user$email %||% user$username
  )
}

connect_group_principal <- function(group) {
  list(guid = group$guid, type = "group", name = group$name, detail = "Group")
}

connect_principal <- function(client, type, guid) {
  path <- if (identical(type, "group")) "groups" else "users"
  promises::then(
    connect_json(connect_req(client, path, guid)),
    if (identical(type, "group")) connect_group_principal else connect_user_principal
  )
}

connect_permissions <- function(client, guid) {
  connect_json(connect_req(client, "content", guid, "permissions"))
}

connect_grant <- function(client, guid, principal_guid, type) {
  connect_json(
    connect_req(client, "content", guid, "permissions") |>
      httr2::req_body_json(list(
        principal_guid = principal_guid,
        principal_type = type,
        role = "viewer"
      ))
  )
}

connect_revoke <- function(client, guid, permission_id) {
  httr2::req_perform_promise(
    connect_req(client, "content", guid, "permissions", permission_id) |>
      httr2::req_method("DELETE")
  )
}

connect_set_access <- function(client, guid, access_type) {
  connect_json(
    connect_req(client, "content", guid) |>
      httr2::req_method("PATCH") |>
      httr2::req_body_json(list(access_type = access_type))
  )
}

connect_delete_content <- function(client, guid) {
  httr2::req_perform_promise(
    connect_req(client, "content", guid) |> httr2::req_method("DELETE")
  )
}

# Who can open this app: its access type and, when that is a list of people,
# the people. Reading the list takes the app's own key; a viewer's key may not
# be allowed to.
connect_app_access <- function(visitor) {
  guid <- connect_content_guid()
  read <- function(client) {
    promises::then(connect_json(connect_req(client, "content", guid)), function(app) {
      access <- list(
        access_type = app$access_type,
        owner_guid = app$owner_guid,
        principals = list()
      )
      if (!identical(app$access_type, "acl")) {
        return(access)
      }
      promises::then(connect_permissions(client, guid), function(principals) {
        access$principals <- principals
        access
      })
    })
  }
  owner <- tryCatch(connect_client(), error = function(err) NULL)
  if (is.null(owner)) {
    return(read(visitor))
  }
  promises::catch(read(owner), function(err) read(visitor))
}

# Everyone who can open the app, as people and groups the share dialog can
# offer: its owner, the people and groups it lists, and those groups'
# members. NULL when the app is open to everyone on the server.
connect_app_people <- function(client, access) {
  if (!identical(access$access_type, "acl")) {
    return(promises::promise_resolve(NULL))
  }
  lookups <- lapply(access$principals, function(p) {
    if (identical(p$principal_type, "group")) {
      connect_group_people(client, p$principal_guid)
    } else {
      promises::then(connect_principal(client, "user", p$principal_guid), function(x) list(x))
    }
  })
  if (!is.null(access$owner_guid)) {
    lookups <- c(lookups, list(promises::then(
      connect_principal(client, "user", access$owner_guid),
      function(x) list(x)
    )))
  }
  # One unreadable person shouldn't hide the rest.
  lookups <- lapply(lookups, function(x) promises::catch(x, function(err) list()))
  promises::then(promises::promise_all(.list = lookups), function(found) {
    people <- unlist(found, recursive = FALSE)
    guids <- vapply(people, `[[`, character(1), "guid")
    unname(people[!duplicated(guids)])
  })
}

connect_group_people <- function(client, guid) {
  group <- connect_principal(client, "group", guid)
  members <- connect_json(connect_req(client, "groups", guid, "members"))
  members <- promises::catch(members, function(err) list(results = list()))
  promises::then(promises::promise_all(group = group, members = members), function(x) {
    c(list(x$group), lapply(x$members$results, connect_user_principal))
  })
}

# The app's link and title, for shared pages and untitled outputs.
connect_app_info <- function() {
  if (exists("app_info", envir = share_cache)) {
    return(share_cache$app_info)
  }
  tryCatch(
    {
      app <- connect_content(connect_client(), connect_content_guid())
      share_cache$app_info <- list(url = app$content_url, title = app$title %||% app$name)
    },
    error = function(err) list()
  )
}

connect_visitor_key <- function(client, token, audience) {
  req <- httr2::request(client$server) |>
    httr2::req_url_path_append(
      "__api__", "v1", "oauth", "integrations", "credentials"
    ) |>
    httr2::req_headers_redacted(Authorization = paste("Key", client$api_key)) |>
    httr2::req_body_form(
      grant_type = "urn:ietf:params:oauth:grant-type:token-exchange",
      subject_token_type = "urn:posit:connect:user-session-token",
      subject_token = token,
      requested_token_type = "urn:posit:connect:api-key",
      audience = audience
    )
  promises::then(
    connect_json(req),
    function(body) body$access_token,
    function(err) {
      # Connect reports an expired or foreign session token as error 215.
      body <- tryCatch(httr2::resp_body_json(err$resp), error = function(e) NULL)
      if (identical(body$error_code, 215L)) {
        share_abort("session", parent = err)
      }
      stop(err)
    }
  )
}

connect_owned_content <- function(client, guid, user_guid) {
  req <- connect_req(client, "content", guid) |>
    httr2::req_error(is_error = function(resp) FALSE)
  promises::then(httr2::req_perform_promise(req), function(resp) {
    # Only a copy that's gone or out of reach is replaced; other failures
    # would orphan the copy people already have links to.
    if (httr2::resp_status(resp) %in% c(403L, 404L)) {
      return(NULL)
    }
    httr2::resp_check_status(resp)
    content <- httr2::resp_body_json(resp)
    if (identical(content$owner_guid, user_guid)) content else NULL
  })
}

# A deploy's task can briefly 404 before it is registered.
connect_wait_task <- coro::async(function(client, id, timeout = 300) {
  deadline <- Sys.time() + timeout
  repeat {
    resp <- await(httr2::req_perform_promise(
      connect_req(client, "tasks", id) |>
        httr2::req_error(is_error = function(resp) FALSE)
    ))
    if (httr2::resp_status(resp) == 200) {
      task <- httr2::resp_body_json(resp)
      if (isTRUE(task$finished)) {
        if (!identical(task$code, 0L)) {
          share_abort("deploy")
        }
        return(task)
      }
    } else if (httr2::resp_status(resp) != 404) {
      httr2::resp_check_status(resp)
    }
    if (Sys.time() > deadline) {
      share_abort("timeout")
    }
    await(promise_sleep(1))
  }
})

connect_json <- function(req) {
  promises::then(httr2::req_perform_promise(req), httr2::resp_body_json)
}

promise_sleep <- function(seconds) {
  promises::promise(function(resolve, reject) {
    later::later(function() resolve(NULL), seconds)
  })
}
