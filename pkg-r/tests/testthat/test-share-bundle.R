shared_agent <- function() {
  agent <- test_agent()
  agent$set_turns(list(
    ellmer::UserTurn(list(ellmer::ContentText("How are orders split?"))),
    ellmer::AssistantTurn(list(ContentProjectedText(
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

  write_conversation_bundle(agent, dir, app = list(url = "https://connect.example.com/app/"))

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
    artifact_document_html("Orders", c(
      "<p>By region</p>",
      "<p>Done</p>",
      share_footer_html(list(url = "https://connect.example.com/app/"))
    ))
  )
  expect_match(html, 'from a <a href="https://connect.example.com/app/"', fixed = TRUE)
})

test_that("a trusted-only agent's conversation is shared without documents", {
  agent <- test_agent(
    semantic_layer = semantic_layer(count_measure_tool()),
    mode = "trusted only"
  )
  agent$set_turns(list(
    ellmer::UserTurn(list(ellmer::ContentText("How many orders?"))),
    ellmer::AssistantTurn(list(ellmer::ContentText("Six.")))
  ))
  dir <- withr::local_tempdir()

  write_conversation_bundle(agent, dir)

  expect_true(file.exists(file.path(dir, "index.html")))
  expect_false(dir.exists(file.path(dir, "documents")))
})

test_that("a restored conversation's documents are shared before they're opened", {
  agent <- test_agent()
  agent$set_turns(list(
    ellmer::UserTurn(list(ellmer::ContentText("Write it."))),
    ellmer::AssistantTurn(list(ellmer::ContentText(
      "<artifact id=\"doc\" title=\"Doc\">\nFirst.\n</artifact>"
    )))
  ))
  store <- agent$artifact_store()
  expect_length(ls(store$artifacts), 0)
  dir <- withr::local_tempdir()

  wait_for_promise(artifact_store_rendered(store))
  write_conversation_bundle(agent, dir)

  expect_match(
    read_utf8(file.path(dir, "documents", "doc.html")),
    "First.",
    fixed = TRUE
  )
})

test_that("a shared document is its rendered page", {
  dir <- withr::local_tempdir()
  artifact <- artifact_get(shared_agent()$artifact_store(), "orders")

  write_document_bundle(artifact, dir)

  expect_setequal(list.files(dir), c("index.html", "manifest.json"))
  expect_identical(
    readChar(file.path(dir, "index.html"), 1e6, useBytes = TRUE),
    artifact_document_html("Orders", c(artifact$html, share_footer_html()))
  )
})

test_that("a bundle's archive holds every file and the manifest", {
  dir <- withr::local_tempdir()
  dir.create(file.path(dir, "documents"))
  writeLines("<p>a</p>", file.path(dir, "index.html"))
  writeLines("<p>b</p>", file.path(dir, "documents", "b.html"))

  write_static_manifest(dir)
  archive <- bundle_archive(dir)

  expect_setequal(
    utils::untar(archive, list = TRUE),
    c("index.html", "documents/b.html", "manifest.json")
  )
})

test_that("a shared plot or table folds its code above the footer", {
  dir <- withr::local_tempdir()
  output <- list(
    kind = "table",
    title = "Orders by region",
    html = "<table><tr><td>EMEA</td></tr></table>",
    code = "commons$run_sql(\"SELECT 1 < 2\")"
  )

  write_output_bundle(output, dir, app = list(url = "https://connect.example.com/app/"))

  html <- read_utf8(file.path(dir, "index.html"))
  expect_match(html, "<details class=\"commons-share-code\"><summary>Code</summary>", fixed = TRUE)
  expect_match(
    html,
    paste0(
      "The code <a href=\"https://connect.example.com/app/\" ",
      "target=\"_blank\" rel=\"noopener\">the data agent</a> ran to make this table:"
    ),
    fixed = TRUE
  )
  expect_match(html, "SELECT 1 &lt; 2", fixed = TRUE)
  expect_lt(
    regexpr("</details>", html, fixed = TRUE),
    regexpr("<footer class=\"commons-share-footer\">", html, fixed = TRUE)
  )
  expect_setequal(list.files(dir), c("index.html", "manifest.json"))
})
