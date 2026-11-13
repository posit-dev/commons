# This class is private to shinychat, which has no API for adding toolbar
# items; we use it knowingly. If shinychat changes it, the conversation's share
# button just doesn't show up, while documents, plots, and tables can still be
# shared. test-share.R checks, off CRAN, that page_chat() still renders it.
shinychat_toolbar_selector <- ".shiny-chat-page-toolbar-global"

# Returns the input the drawer's share control sets, or NULL when this
# session can't share.
share_server <- function(id, client, chat, session) {
  if (!is_connect_runtime()) {
    return(NULL)
  }
  token <- session$request$HTTP_POSIT_CONNECT_USER_SESSION_TOKEN
  if (is.null(token)) {
    return(NULL)
  }
  # Attaching an integration restarts the app, so let this session reconnect
  # to the new process rather than show as disconnected.
  audience <- connect_share_audience(
    before_attach = function() session$allowReconnect("force")
  )
  if (is.null(audience)) {
    return(NULL)
  }

  store <- client$artifact_store()
  ids <- share_ids_for(id)
  receipts <- share_receipts(chat)
  app <- connect_app_info()
  input <- session$input
  output <- session$output
  ns <- session$ns
  # `current` is the share the open dialog shows; `busy` is the share being
  # published, until its deploy settles, which can outlast the dialog.
  state <- new.env(parent = emptyenv())
  state$current <- NULL
  state$busy <- NULL
  view <- shiny::reactiveValues(
    url = NULL,
    owner = NULL,
    people = list(),
    loading = TRUE,
    results = list(),
    empty = NULL,
    access = "restricted",
    app_access = NULL,
    status = NULL
  )

  # Viewer accounts can't publish, so they aren't offered the button. If the
  # role can't be read, the button shows and a share reports what went wrong.
  can_share <- shiny::reactiveVal(NULL)
  promises::then(
    connect_visitor_role(token, audience),
    function(role) can_share(!identical(role, "viewer")),
    function(err) can_share(TRUE)
  )

  # Copies a share's state into the dialog, unless another share replaced it.
  show <- function(share, ...) {
    if (!identical(state$current, share)) {
      return(invisible())
    }
    fields <- list(...)
    for (name in names(fields)) {
      view[[name]] <- fields[[name]]
    }
  }

  fail <- function(share, err, what) {
    if (!inherits(err, "commons_share_error")) {
      cli::cli_warn("{what} on Posit Connect failed.", parent = err)
    }
    message <- share_error_message(err)
    if (share$closed) {
      shiny::showNotification(message, type = "error", session = session)
    } else if (is.null(share$content) && identical(state$current, share)) {
      # Without a link, nothing else in the dialog can work.
      share$closed <- TRUE
      state$current <- NULL
      share_modal(share$target$heading, message)
    } else {
      show(share, status = list(text = message, error = TRUE))
    }
  }

  # A share the viewer acted on is kept when the dialog closes.
  touch <- function(share) {
    share$touched <- TRUE
    if (identical(state$current, share)) {
      shiny::updateActionButton(session, ids$done, label = "Done")
    }
  }

  release <- function(share) {
    if (identical(state$busy, share)) {
      state$busy <- NULL
    }
  }

  shiny::observeEvent(can_share(), once = TRUE, {
    if (isTRUE(can_share())) {
      share_insert_ui(ns, ids, session)
    }
  })
  output[[ids$people]] <- shiny::renderUI(
    share_people_ui(view$owner, view$people, ns(ids$remove), view$loading)
  )
  output[[ids$results]] <- shiny::renderUI(
    share_results_ui(view$results, ns(ids$add), view$empty)
  )
  output[[ids$note]] <- shiny::renderUI(
    share_access_note(view$access, view$app_access)
  )
  output[[ids$link]] <- shiny::renderUI(share_copy_button(view$url, ns(ids$copy)))
  output[[ids$status]] <- shiny::renderUI(
    share_status_ui(view$status, ns(ids$update))
  )

  offer <- function(target) {
    if (is.null(target$title)) {
      target$title <- share_title(
        share_fallback_title(app$title, target$noun %||% target$kind)
      )
    }
    if (!is.null(state$busy)) {
      return(share_modal(target$heading, "A copy is still being published."))
    }
    target$conversation <- receipts$conversation_id()
    receipt <- receipts$get(target$key)
    share <- new.env(parent = emptyenv())
    share$target <- target
    share$receipt <- receipt
    share$people <- list()
    share$inherited <- receipt$inherited %||% list()
    share$access <- receipt$general %||% "restricted"
    share$applied <- share$access
    share$touched <- FALSE
    share$closed <- FALSE
    share$abandoned <- FALSE
    state$current <- share
    state$busy <- share
    show(
      share,
      url = receipt$url,
      owner = NULL,
      people = list(),
      loading = TRUE,
      results = list(),
      empty = NULL,
      access = share$access,
      app_access = NULL,
      status = NULL
    )
    shiny::showModal(share_dialog(target, share$access, ids, ns, first = is.null(receipt)))
    publish(share)
  }

  # Opens the share's copy, making one if there isn't one yet. A new copy is
  # published right away; an existing one only when the viewer asks.
  publish <- function(share) {
    target <- share$target
    opened <- connect_share_open(
      token,
      audience,
      target$title,
      guid = share$receipt$guid
    )
    done <- promises::then(opened, function(opened) {
      share$visitor <- opened$visitor
      share$user <- opened$user
      share$content <- opened$content
      share$created <- opened$created
      # Remembering new content before its deploy means a retry after a
      # failure updates it rather than making another.
      if (opened$created) {
        # A replaced copy's access choices don't carry over to the new one.
        receipts$forget(target)
        receipts$remember(target, opened$content)
        share$inherited <- list()
        share$access <- "restricted"
        share$applied <- "restricted"
        # The receipt's copy may be gone, so the dialog shows the new one.
        if (identical(state$current, share)) {
          shiny::updateSelectInput(
            session,
            ids$access,
            selected = share$pending_access %||% "restricted"
          )
          if (!share$touched) {
            shiny::updateActionButton(session, ids$done, label = "Cancel")
          }
        }
      }
      if (share$closed && !share$touched && share$created) {
        return(abandon(share))
      }
      show(
        share,
        url = opened$content$content_url,
        owner = connect_user_principal(opened$user),
        loading = !opened$created,
        access = share$access
      )
      # Who can open the app bounds who the search offers; NULL means
      # everyone on the server can, so a failure offers no one.
      share$audience <- promises::then(connect_app_access(share$visitor), function(access) {
        show(share, app_access = access$access_type)
        connect_app_people(share$visitor, access)
      })
      share$audience <- promises::catch(share$audience, function(err) list())
      if (!opened$created) {
        load_people(share)
      }
      if (!is.null(share$pending_access)) {
        set_access(share, share$pending_access)
      }
      if (opened$created) {
        return(deploy(share))
      }
      if (!identical(share$receipt$fingerprint, share_fingerprint(client, target))) {
        show(share, status = list(text = share_stale_text(target$kind), update = TRUE))
      }
    })
    done <- promises::catch(done, function(err) {
      if (!share$abandoned) {
        show(share, loading = FALSE)
        fail(share, err, "Sharing")
      }
    })
    promises::finally(done, function() release(share))
  }

  deploy <- function(share) {
    target <- share$target
    state$busy <- share
    show(share, status = list(text = "Publishing the latest version\u2026", busy = TRUE))
    ready <- if (identical(target$kind, "conversation")) {
      artifact_store_rendered(store)
    } else {
      promises::promise_resolve(NULL)
    }
    done <- promises::then(ready, function(...) {
      fingerprint <- share_fingerprint(client, target)
      deployed <- connect_share_deploy(
        share$visitor,
        share$content$guid,
        share_archive(client, target, app)
      )
      promises::then(deployed, function(...) fingerprint)
    })
    done <- promises::then(done, function(fingerprint) {
      if (share$abandoned) {
        return(invisible())
      }
      receipts$remember(target, share$content)
      receipts$update(target, list(fingerprint = fingerprint))
      save_history()
      show(share, status = NULL)
    })
    done <- promises::catch(done, function(err) {
      if (!share$abandoned) {
        fail(share, err, "Sharing")
      }
    })
    promises::finally(done, function() release(share))
  }

  # A first share closed before anyone could use its link leaves nothing.
  abandon <- function(share) {
    share$abandoned <- TRUE
    release(share)
    receipts$forget(share$target)
    promises::catch(
      connect_delete_content(share$visitor, share$content$guid),
      function(err) NULL
    )
  }

  load_people <- function(share) {
    inherited <- names(share$inherited)
    people <- promises::then(
      connect_permissions(share$visitor, share$content$guid),
      function(permissions) {
        explicit <- Filter(
          function(p) !p$principal_guid %in% c(inherited, share$user$guid),
          permissions
        )
        promises::promise_all(.list = lapply(explicit, function(p) {
          promises::then(
            connect_principal(share$visitor, p$principal_type, p$principal_guid),
            function(person) {
              person$permission_id <- p$id
              person
            }
          )
        }))
      }
    )
    promises::then(
      people,
      function(people) {
        share$people <- unname(people)
        show(share, people = share$people, loading = FALSE)
      },
      function(err) {
        show(share, loading = FALSE)
        fail(share, err, "Reading who can see the copy")
      }
    )
  }

  set_access <- function(share, access) {
    if (is.null(share$content)) {
      share$pending_access <- if (!identical(access, share$access)) access
      return(invisible())
    }
    share$pending_access <- NULL
    share$access <- access
    # Changes run one at a time, so one made quickly after another sees the
    # grants the first made.
    ready <- promises::catch(
      share$applying %||% promises::promise_resolve(NULL),
      function(err) NULL
    )
    share$applying <- promises::then(ready, function(...) apply_access(share, access))
    invisible(share$applying)
  }

  apply_access <- function(share, access) {
    visitor <- share$visitor
    guid <- share$content$guid
    applied <- if (identical(access, "app")) {
      promises::then(connect_app_access(visitor), function(app) {
        show(share, app_access = app$access_type)
        if (!identical(app$access_type, "acl")) {
          return(connect_set_access(visitor, guid, app$access_type))
        }
        promises::then(connect_set_access(visitor, guid, "acl"), function(...) {
          # The app's permissions don't list its owner.
          owner <- if (!is.null(app$owner_guid)) {
            list(list(principal_guid = app$owner_guid, principal_type = "user"))
          }
          inherit_people(share, c(app$principals, owner))
        })
      })
    } else {
      promises::then(connect_set_access(visitor, guid, "acl"), function(...) {
        revoke_inherited(share)
      })
    }
    promises::then(
      applied,
      function(...) {
        share$applied <- access
        receipts$update(share$target, list(
          general = access,
          inherited = share$inherited
        ))
        save_history()
      },
      function(err) {
        # A change queued after this one still runs, so only the latest is undone.
        if (identical(share$access, access)) {
          share$access <- share$applied
          show(share, access = share$applied)
          shiny::updateSelectInput(session, ids$access, selected = share$applied)
        }
        fail(share, err, "Changing who can see the copy")
      }
    )
  }

  # Grants the app's people access, remembering which grants came from the
  # app so choosing "Restricted" again removes only those.
  inherit_people <- function(share, principals) {
    taken <- c(
      share$user$guid,
      vapply(share$people, `[[`, character(1), "guid"),
      names(share$inherited)
    )
    principals <- Filter(function(p) !p$principal_guid %in% taken, principals)
    principals <- principals[!duplicated(vapply(principals, `[[`, character(1), "principal_guid"))]
    grants <- lapply(principals, function(p) {
      promises::then(
        connect_grant(share$visitor, share$content$guid, p$principal_guid, p$principal_type),
        function(permission) {
          share$inherited[[p$principal_guid]] <- permission$id
        }
      )
    })
    promises::promise_all(.list = grants)
  }

  revoke_inherited <- function(share) {
    revokes <- lapply(names(share$inherited), function(guid) {
      promises::then(
        connect_revoke(share$visitor, share$content$guid, share$inherited[[guid]]),
        function(...) share$inherited[[guid]] <- NULL
      )
    })
    promises::promise_all(.list = revokes)
  }

  save_history <- function() {
    # Receipts are saved with the conversation, which otherwise saves only
    # when an answer finishes.
    tryCatch(chat$history$save(), error = function(err) NULL)
  }

  shiny::observeEvent(input[[ids$open]], {
    if (identical(chat$status(), "streaming")) {
      share_modal("Share this conversation", "Wait for the answer to finish.")
    } else if (length(client$get_turns()) == 0) {
      share_modal("Share this conversation", "There's nothing to share yet.")
    } else {
      offer(share_conversation_target(shinychat_title(id, session)))
    }
  })

  shiny::observeEvent(input[[ids$document]], {
    artifact <- artifact_get(store, input[[ids$document]]$artifact)
    if (!is.null(artifact) && identical(artifact$status, "ready")) {
      offer(share_document_target(artifact))
    }
  })

  shiny::observeEvent(input[[ids$output]], {
    target <- share_output_target(client, input[[ids$output]]$id)
    # ellmer adds a tool result to the turns only once the answer finishes.
    if (is.null(target) && identical(chat$status(), "streaming")) {
      share_modal("Share", "Wait for the answer to finish.")
    } else if (is.null(target)) {
      share_modal("Share", "This is no longer in the conversation, so it can't be shared.")
    } else {
      offer(target)
    }
  })

  shiny::observeEvent(input[[ids$update]], {
    share <- state$current
    if (!is.null(share) && !is.null(share$content) && is.null(state$busy)) {
      deploy(share)
    }
  })

  search <- shiny::debounce(shiny::reactive(input[[ids$search]]), 250)
  shiny::observeEvent(search(), ignoreNULL = FALSE, {
    share <- state$current
    query <- trimws(search() %||% "")
    if (is.null(share) || is.null(share$visitor) || nchar(query) < 2) {
      view$results <- list()
      view$empty <- NULL
      return()
    }
    found <- promises::then(share$audience, function(audience) {
      if (is.null(audience)) {
        promises::then(
          connect_search_principals(share$visitor, query),
          function(people) list(people = people, scoped = FALSE)
        )
      } else {
        list(people = share_filter_people(audience, query), scoped = TRUE)
      }
    })
    promises::then(
      found,
      function(found) {
        taken <- c(
          share$user$guid,
          vapply(share$people, `[[`, character(1), "guid")
        )
        results <- Filter(function(p) !p$guid %in% taken, found$people)
        empty <- if (length(results) == 0) {
          if (found$scoped) "No one with access to this app matches." else "No one matches."
        }
        show(share, results = results, empty = empty)
      },
      function(err) fail(share, err, "Searching people")
    )
  })

  shiny::observeEvent(input[[ids$add]], {
    share <- state$current
    guid <- input[[ids$add]]$guid
    person <- Find(function(p) identical(p$guid, guid), view$results)
    if (is.null(share) || is.null(share$content) || is.null(person)) {
      return()
    }
    touch(share)
    shiny::updateTextInput(session, ids$search, value = "")
    view$results <- list()
    view$empty <- NULL
    granted <- if (!is.null(share$inherited[[guid]])) {
      # Already a viewer through the app's access; now they're on the list
      # in their own right.
      id <- share$inherited[[guid]]
      share$inherited[[guid]] <- NULL
      promises::promise_resolve(list(id = id))
    } else {
      connect_grant(share$visitor, share$content$guid, guid, person$type)
    }
    promises::then(
      granted,
      function(permission) {
        person$permission_id <- permission$id
        share$people <- c(share$people, list(person))
        show(share, people = share$people)
        receipts$update(share$target, list(inherited = share$inherited))
        save_history()
      },
      function(err) fail(share, err, "Adding a person")
    )
  })

  shiny::observeEvent(input[[ids$remove]], {
    share <- state$current
    guid <- input[[ids$remove]]$guid
    person <- Find(function(p) identical(p$guid, guid), share$people)
    if (is.null(share) || is.null(person)) {
      return()
    }
    touch(share)
    promises::then(
      connect_revoke(share$visitor, share$content$guid, person$permission_id),
      function(...) {
        share$people <- Filter(function(p) !identical(p$guid, guid), share$people)
        show(share, people = share$people)
      },
      function(err) fail(share, err, "Removing a person")
    )
  })

  shiny::observeEvent(input[[ids$access]], {
    share <- state$current
    access <- input[[ids$access]]
    if (is.null(share) || identical(access, share$pending_access %||% share$access)) {
      return()
    }
    touch(share)
    view$access <- access
    set_access(share, access)
  })

  shiny::observeEvent(input[[ids$copy]], {
    if (!is.null(state$current)) {
      touch(state$current)
    }
  })

  shiny::observeEvent(input[[ids$done]], {
    share <- state$current
    shiny::removeModal(session)
    if (is.null(share)) {
      return()
    }
    share$closed <- TRUE
    state$current <- NULL
    if (share$created %||% FALSE && !share$touched && !is.null(share$content)) {
      abandon(share)
    }
  })

  ns(ids$document)
}

share_ids_for <- function(id) {
  inputs <- c(
    "open", "document", "output", "search", "add", "remove", "access",
    "copy", "done", "update", "people", "results", "note", "link", "status"
  )
  ids <- as.list(paste0(id, "_share_", inputs))
  names(ids) <- inputs
  ids$document <- paste0(id, "_artifact_share")
  ids
}

# The config and script go in the body rather than the toolbar, so documents,
# plots, and tables can be shared even when the toolbar can't be found.
share_insert_ui <- function(ns, ids, session) {
  shiny::insertUI(
    "body",
    where = "beforeEnd",
    ui = htmltools::tagList(
      share_config_tag(ns(ids$output)),
      commons_share_dependency()
    ),
    immediate = TRUE,
    session = session
  )
  shiny::insertUI(
    shinychat_toolbar_selector,
    where = "afterBegin",
    ui = bslib::toolbar(
      bslib::toolbar_input_button(
        ns(ids$open),
        label = "Share",
        icon = share_icon(),
        tooltip = "Share conversation"
      )
    ),
    immediate = TRUE,
    session = session
  )
}

# Receipts belong to the conversation rather than its turns, so editing a
# message or switching branches keeps them and a new chat drops them.
share_receipts <- function(chat) {
  saved <- list()
  chat$history$on_restore(function(values) {
    saved <<- values$commons_shares %||% list()
  })
  chat$history$on_save(function(values) {
    values$commons_shares <- saved
    values
  })
  shiny::observeEvent(
    chat$history$conversation_id(),
    {
      if (is.null(chat$history$conversation_id())) {
        saved <<- list()
      }
    },
    ignoreNULL = FALSE,
    ignoreInit = TRUE
  )
  conversation_id <- function() shiny::isolate(chat$history$conversation_id())
  # A share that finishes after the user moved to another conversation
  # mustn't become that conversation's copy.
  ours <- function(target) identical(target$conversation, conversation_id())
  list(
    conversation_id = conversation_id,
    get = function(key) saved[[key]],
    remember = function(target, content) {
      receipt <- share_receipt(content)
      if (ours(target)) {
        saved[[target$key]] <<- utils::modifyList(saved[[target$key]] %||% list(), receipt)
      }
      receipt
    },
    update = function(target, fields) {
      if (ours(target) && !is.null(saved[[target$key]])) {
        saved[[target$key]][names(fields)] <<- fields
      }
    },
    forget = function(target) {
      if (ours(target)) {
        saved[[target$key]] <<- NULL
      }
    }
  )
}

share_conversation_target <- function(title = NULL) {
  list(
    kind = "conversation",
    key = "conversation",
    heading = "Share this conversation",
    title = if (!is.null(title)) share_title(title)
  )
}

# The title shinychat gave the conversation, from the model or a rename.
# Reads shinychat internals as a workaround until it exposes the title:
# https://github.com/posit-dev/shinychat/issues/471
shinychat_title <- function(id, session) {
  # Any change to those internals falls back to the default title rather than
  # erroring in the observer, which would end the session.
  tryCatch(
    {
      record <- utils::getFromNamespace("get_session_chat_bookmark_info", "shinychat")(
        session,
        paste0(id, ".history-controller")
      )$record
      # Without a `title_source`, the title is a placeholder: the first message.
      if (is.null(record$title_source) || !rlang::is_string(record$title)) {
        return(NULL)
      }
      record$title
    },
    error = function(e) NULL
  )
}

share_document_target <- function(artifact) {
  list(
    kind = "document",
    id = artifact$id,
    key = paste0("document:", artifact$id),
    heading = "Share this document",
    title = share_title(artifact$title)
  )
}

# `id` names a plot or table wrapped by share_wrap().
share_output_target <- function(client, id) {
  if (!rlang::is_string(id)) {
    return(NULL)
  }
  output <- share_output_find(client$get_turns(), id)
  if (is.null(output)) {
    return(NULL)
  }
  noun <- if (identical(output$kind, "table")) "table" else "figure"
  # Without a title of its own, an output is named for the question it answered.
  title <- output$title %||%
    (if (!is.null(output$question)) truncate_title(output$question))
  list(
    kind = "output",
    key = paste0("output:", id),
    heading = paste("Share this", noun),
    title = if (!is.null(title)) share_title(title),
    html = output$html,
    code = output$code,
    noun = output$kind
  )
}

# A conversation or output without a title of its own is named for the app it
# came from.
share_fallback_title <- function(app_title, noun) {
  noun <- if (noun %in% c("table", "conversation")) noun else "figure"
  if (is.null(app_title) || !nzchar(app_title)) {
    return(paste("Shared", noun))
  }
  sprintf("%s (%s)", app_title, noun)
}

# People whose name or email contains `query`, and groups whose name does.
share_filter_people <- function(people, query, limit = 8) {
  query <- tolower(query)
  hits <- Filter(function(p) {
    grepl(query, tolower(p$name), fixed = TRUE) ||
      (identical(p$type, "user") && grepl(query, tolower(p$detail %||% ""), fixed = TRUE))
  }, people)
  utils::head(hits, limit)
}

# What a copy shows, to tell whether it changed since it was published.
share_fingerprint <- function(client, target) {
  store <- client$artifact_store()
  documents <- if (!is.null(store)) sort(ls(store$artifacts))
  shown <- switch(
    target$kind,
    conversation = list(
      wire_messages_json(shared_messages(client)),
      lapply(documents, function(id) artifact_get(store, id)$html)
    ),
    document = {
      artifact <- artifact_get(store, target$id)
      list(artifact$title, artifact$html)
    },
    target[c("title", "html", "code")]
  )
  rlang::hash(shown)
}

share_stale_text <- function(kind) {
  switch(
    kind,
    conversation = "The conversation has changed since this copy was published.",
    document = "The document has changed since this copy was published.",
    "This copy may be out of date."
  )
}

share_archive <- function(client, target, app = list()) {
  dir <- tempfile("commons-share-")
  dir.create(dir)
  switch(
    target$kind,
    conversation = write_conversation_bundle(client, dir, app, target$title),
    document = write_document_bundle(
      artifact_get(client$artifact_store(), target$id),
      dir,
      app
    ),
    output = write_output_bundle(
      list(kind = target$noun, title = target$title, html = target$html, code = target$code),
      dir,
      app
    )
  )
  bundle_archive(dir)
}

# Connect requires a title of 3 to 1024 characters without line breaks.
share_title <- function(title) {
  title <- trimws(gsub("[\t\n\f\r]+", " ", title))
  if (nchar(title) < 3) "Shared copy" else substr(title, 1, 1024)
}

share_receipt <- function(content) {
  list(
    guid = content$guid,
    url = content$content_url,
    dashboard_url = content$dashboard_url
  )
}

# Until the viewer acts on a first share, closing the dialog discards the
# copy, so its button reads "Cancel".
share_dialog <- function(target, access, ids, ns, first = TRUE) {
  search <- shiny::textInput(
    ns(ids$search),
    label = NULL,
    width = "100%",
    placeholder = "Add people and groups"
  )
  search <- htmltools::tagQuery(search)$
    find("input")$
    addAttrs(autocomplete = "off", `aria-label` = "Add people and groups")$
    allTags()
  access_label <- paste0(ns(ids$access), "-label")
  access_input <- shiny::selectInput(
    ns(ids$access),
    label = NULL,
    choices = c(
      "Restricted" = "restricted",
      "Anyone who can access this app" = "app"
    ),
    selected = access,
    selectize = FALSE,
    width = "fit-content"
  )
  access_input <- htmltools::tagQuery(access_input)$
    find("select")$
    addAttrs(`aria-labelledby` = access_label)$
    allTags()
  # Live regions sit outside renderUI, which would recreate them with their
  # text already in place, and screen readers don't announce that.
  share_modal_dialog(
    title = sprintf("Share \u201c%s\u201d", truncate_title(target$title, 60)),
    htmltools::div(
      class = "commons-share-dialog",
      search,
      shiny::uiOutput(ns(ids$results), role = "status"),
      htmltools::h6("People with access"),
      # Shiny replaces the placeholder once the people are known.
      htmltools::div(
        id = ns(ids$people),
        class = "shiny-html-output",
        share_people_ui(NULL, list(), NULL, loading = TRUE)
      ),
      htmltools::h6(id = access_label, "General access"),
      htmltools::div(
        class = "commons-share-access",
        access_input,
        shiny::uiOutput(ns(ids$note))
      ),
      shiny::uiOutput(ns(ids$status), role = "status")
    ),
    footer = htmltools::div(
      class = "commons-share-actions",
      htmltools::div(
        id = ns(ids$link),
        class = "shiny-html-output",
        role = "status",
        share_copy_button(NULL, NULL)
      ),
      shiny::actionButton(ns(ids$done), if (first) "Cancel" else "Done", class = "btn-primary")
    ),
    easyClose = FALSE
  )
}

share_people_ui <- function(owner, people, remove_id, loading = FALSE) {
  rows <- lapply(people, function(person) {
    share_person_row(
      person,
      htmltools::span(class = "commons-share-role", "Viewer"),
      htmltools::tags$button(
        type = "button",
        class = "btn-close commons-share-remove",
        `aria-label` = paste("Remove", person$name),
        `data-input` = remove_id,
        `data-guid` = person$guid
      )
    )
  })
  if (!is.null(owner)) {
    owner$name <- paste(owner$name, "(you)")
    rows <- c(
      list(share_person_row(owner, htmltools::span(class = "commons-share-role", "Owner"))),
      rows
    )
  }
  if (loading) {
    rows <- c(rows, list(share_person_placeholder()))
    if (is.null(owner)) {
      rows <- c(rows, list(share_person_placeholder()))
    }
  }
  htmltools::div(
    class = "commons-share-people",
    `aria-busy` = if (loading) "true",
    rows
  )
}

share_person_placeholder <- function() {
  htmltools::div(
    class = "commons-share-person-row placeholder-glow",
    `aria-hidden` = "true",
    htmltools::span(class = "commons-share-avatar placeholder"),
    htmltools::div(
      class = "commons-share-placeholder-text",
      htmltools::span(class = "placeholder col-6"),
      htmltools::span(class = "placeholder placeholder-sm col-8")
    )
  )
}

share_results_ui <- function(results, add_id, empty = NULL) {
  if (length(results) == 0) {
    if (is.null(empty)) {
      return(NULL)
    }
    return(htmltools::p(class = "commons-share-empty", empty))
  }
  htmltools::div(
    class = "list-group commons-share-results",
    lapply(results, function(person) {
      htmltools::tags$button(
        type = "button",
        class = "list-group-item list-group-item-action commons-share-pick",
        `data-input` = add_id,
        `data-guid` = person$guid,
        share_person_tag(person)
      )
    })
  )
}

share_person_row <- function(person, ...) {
  htmltools::div(class = "commons-share-person-row", share_person_tag(person), ...)
}

share_person_tag <- function(person) {
  htmltools::div(
    class = "commons-share-person",
    htmltools::span(
      class = "commons-share-avatar",
      `aria-hidden` = "true",
      toupper(substr(person$name, 1, 1))
    ),
    htmltools::div(
      htmltools::div(class = "commons-share-name", person$name),
      htmltools::div(class = "commons-share-detail", person$detail)
    )
  )
}

# "Anyone who can access this app" copies the app's access, which ranges from
# a list of people to anyone on the internet.
share_access_note <- function(access, app_access = NULL) {
  text <- if (!identical(access, "app")) {
    "Only people with access can open it with the link."
  } else if (identical(app_access, "all")) {
    "Anyone with the link can open it, without signing in."
  } else if (identical(app_access, "logged_in")) {
    "Anyone signed in to Posit Connect can open it with the link."
  } else {
    paste(
      "Anyone who can open this app can open it with the link.",
      if (identical(app_access, "acl")) {
        "People given access to the app later won't be added."
      }
    )
  }
  htmltools::div(
    class = "commons-share-note",
    bsicons::bs_icon(if (identical(access, "app")) "people" else "lock"),
    htmltools::span(text)
  )
}

share_copy_button <- function(url, copy_id) {
  htmltools::tags$button(
    type = "button",
    class = "btn btn-outline-primary commons-share-copy",
    disabled = if (is.null(url)) NA,
    `data-url` = url,
    `data-input` = copy_id,
    if (is.null(url)) share_spinner() else bsicons::bs_icon("link-45deg"),
    if (is.null(url)) "Preparing link\u2026" else "Copy link"
  )
}

share_status_ui <- function(status, update_id = NULL) {
  if (is.null(status)) {
    return(NULL)
  }
  htmltools::p(
    class = paste(
      "commons-share-status",
      if (isTRUE(status$error)) "text-danger" else "text-body-secondary"
    ),
    if (isTRUE(status$busy)) share_spinner(),
    htmltools::span(status$text),
    if (isTRUE(status$update)) {
      htmltools::tags$button(
        type = "button",
        class = "btn btn-sm btn-outline-primary commons-share-update",
        `data-input` = update_id,
        "Update copy"
      )
    }
  )
}

# Tells commons-share.js where an output button's click goes, and gives it the
# icon to draw.
share_config_tag <- function(output_input) {
  htmltools::span(
    class = "commons-share-config",
    hidden = NA,
    `data-output-input` = output_input,
    share_icon()
  )
}

# Bootstrap's box-arrow-up, inline because bsicons is optional.
share_icon <- function() {
  htmltools::HTML('<svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" fill="currentColor" viewBox="0 0 16 16" aria-hidden="true"><path fill-rule="evenodd" d="M3.5 6a.5.5 0 0 0-.5.5v8a.5.5 0 0 0 .5.5h9a.5.5 0 0 0 .5-.5v-8a.5.5 0 0 0-.5-.5h-2a.5.5 0 0 1 0-1h2A1.5 1.5 0 0 1 14 6.5v8a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 2 14.5v-8A1.5 1.5 0 0 1 3.5 5h2a.5.5 0 0 1 0 1z"/><path fill-rule="evenodd" d="M7.646.146a.5.5 0 0 1 .708 0l3 3a.5.5 0 0 1-.708.708L8.5 1.707V10.5a.5.5 0 0 1-1 0V1.707L5.354 3.854a.5.5 0 1 1-.708-.708z"/></svg>')
}

share_spinner <- function() {
  htmltools::span(class = "spinner-border spinner-border-sm", `aria-hidden` = "true")
}

commons_share_dependency <- function() {
  src <- system.file("www", "commons-share", package = "commons")
  stamp <- max(file.mtime(list.files(src, full.names = TRUE)))
  htmltools::htmlDependency(
    name = "commons-share",
    version = paste0("0.0.0.9000.", as.integer(stamp)),
    src = c(file = src),
    script = "commons-share.js",
    stylesheet = "commons-share.css"
  )
}

share_modal <- function(title, text) {
  shiny::showModal(share_modal_dialog(
    title = title,
    htmltools::p(text),
    footer = shiny::modalButton("Close"),
    easyClose = TRUE
  ))
}

# Shiny's dialog has no accessible name. The class tells commons-share.js to
# return focus to whatever opened the dialog once it closes.
share_modal_dialog <- function(...) {
  htmltools::tagQuery(shiny::modalDialog(...))$
    addClass("commons-share-modal")$
    addAttrs(`aria-labelledby` = "commons-share-modal-title")$
    find(".modal-title")$
    addAttrs(id = "commons-share-modal-title")$
    allTags()
}

share_abort <- function(reason, parent = NULL, call = rlang::caller_env()) {
  cli::cli_abort(
    share_error_messages[[reason]],
    class = "commons_share_error",
    parent = parent,
    call = call
  )
}

share_error_messages <- list(
  role = paste(
    "Your Connect account can't publish content. Ask your Connect",
    "administrator for a Publisher account."
  ),
  session = "Your Connect session has expired. Reload the page and try again.",
  deploy = "Posit Connect couldn't deploy the copy. Try again.",
  timeout = "Posit Connect took too long to deploy the copy. Try again."
)

share_error_message <- function(err) {
  if (inherits(err, "commons_share_error")) {
    return(conditionMessage(err))
  }
  "Couldn't share to Posit Connect. Try again."
}
