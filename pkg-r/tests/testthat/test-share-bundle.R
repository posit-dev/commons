shared_agent <- function() {
  agent <- test_agent()
  agent$set_turns(list(
    ellmer::UserTurn(list(ellmer::ContentText("How are orders split?"))),
    ellmer::AssistantTurn(list(ContentDisplayText(
      text = "<artifact id=\"orders\" title=\"Orders\">...</artifact>Split.",
      display = "<commons-artifact-link artifact=\"orders\" version=\"1\">Orders</commons-artifact-link>Split."
    )))
  ))
  artifact <- artifact_ensure(agent$artifact_store(), "orders")
  artifact$title <- "Orders"
  artifact$versions <- list(list(source = "..."))
  artifact$html <- c("<p>By region</p>", "<p>Done</p>")
  artifact$status <- "ready"
  agent
}

test_that("a shared conversation shows what the user saw, without Shiny", {
  agent <- shared_agent()
  dir <- withr::local_tempdir()

  write_conversation_bundle(agent, dir, shared_on = as.Date("2026-10-08"))

  messages <- jsonlite::fromJSON(
    wire_messages_json(shared_messages(agent)),
    simplifyVector = FALSE
  )
  expect_identical(messages[[1]]$segments[[1]]$content, "How are orders split?")
  expect_identical(
    messages[[2]]$segments[[1]]$content,
    agent$get_turns()[[2]]@contents[[1]]@display
  )

  html <- read_utf8(file.path(dir, "index.html"))
  expect_match(html, "data-initial-messages=", fixed = TRUE)
  expect_match(html, '{"orders":"documents/orders.html"}', fixed = TRUE)
  expect_false(grepl("shiny.min.js", html, fixed = TRUE))
  expect_identical(
    readChar(file.path(dir, "documents", "orders.html"), 1e6, useBytes = TRUE),
    artifact_document_html("Orders", c("<p>By region</p>", "<p>Done</p>"))
  )
})

test_that("a shared document is its rendered page", {
  dir <- withr::local_tempdir()
  artifact <- artifact_get(shared_agent()$artifact_store(), "orders")

  write_document_bundle(artifact, dir)

  expect_setequal(list.files(dir), c("index.html", "manifest.json"))
  expect_identical(
    readChar(file.path(dir, "index.html"), 1e6, useBytes = TRUE),
    artifact_document_html("Orders", artifact$html)
  )
})

test_that("the manifest lists every bundled file as static content", {
  dir <- withr::local_tempdir()
  dir.create(file.path(dir, "documents"))
  writeLines("<p>a</p>", file.path(dir, "index.html"))
  writeLines("<p>b</p>", file.path(dir, "documents", "b.html"))

  write_static_manifest(dir)

  manifest <- jsonlite::read_json(file.path(dir, "manifest.json"))
  expect_identical(manifest$metadata$appmode, "static")
  expect_identical(manifest$metadata$primary_html, "index.html")
  expect_setequal(names(manifest$files), c("index.html", "documents/b.html"))
  expect_identical(
    manifest$files[["documents/b.html"]]$checksum,
    unname(tools::md5sum(file.path(dir, "documents", "b.html")))
  )

  archive <- bundle_archive(dir)
  expect_setequal(
    utils::untar(archive, list = TRUE),
    c("index.html", "documents/b.html", "manifest.json")
  )
})
