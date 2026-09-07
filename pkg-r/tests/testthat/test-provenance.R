test_that("provenance information control is the web component", {
  expect_identical(
    provenance_info_control(),
    paste0(
      '<commons-provenance-info class="commons-provenance-info">',
      "</commons-provenance-info>"
    )
  )
})

test_that("derive_provenance_tag matches the shared truth table", {
  cases <- shared_fixture("provenance")$derive_provenance_tag$cases
  # An empty table would make the loop below vacuously succeed.
  expect_gt(length(cases), 0)

  for (case in cases) {
    tags <- vapply(case$tags, as.character, character(1))
    expected <- if (is.null(case$expected)) NA_character_ else case$expected
    expect_identical(
      derive_provenance_tag(tags, case$verified),
      expected,
      info = case$name
    )
  }
})

test_that("collect_appended_tags matches the shared fixture", {
  cases <- shared_fixture("provenance")$collect_appended_tags$cases
  # An empty fixture would make the loop below vacuously succeed.
  expect_gt(length(cases), 0)

  for (case in cases) {
    turns <- lapply(case$turns, function(turn) {
      contents <- lapply(turn$contents, function(content) {
        if (content$type == "text") {
          return(ellmer::ContentText(text = content$text))
        }
        ellmer::ContentToolResult(
          value = "42",
          request = NULL,
          extra = drop_nulls(list(commons_tag = content$tag))
        )
      })
      if (turn$role == "assistant") {
        ellmer::AssistantTurn(contents = contents)
      } else {
        ellmer::UserTurn(contents = contents)
      }
    })

    # `skip` counts the turns present when the exchange began; from_index is
    # 1-based here and 0-based in Python.
    expect_identical(
      collect_appended_tags(turns, from_index = case$skip + 1),
      as.character(unlist(case$expected)),
      info = case$name
    )
  }
})

test_that("provenance_display uses R display copy", {
  display <- shared_fixture("provenance")$provenance_display$tags
  expect_setequal(names(display), names(provenance_display))

  for (tag in names(display)) {
    entry <- provenance_display[[tag]]
    expected <- display[[tag]]
    expect_identical(entry$label, expected$label, info = tag)
    expect_identical(entry$body, expected$body, info = tag)
    expect_identical(entry$icon, expected$icon, info = tag)
    expect_identical(entry$pill_class, expected$pill_class, info = tag)
  }
})

test_that("provenance_aside matches the shared fixture", {
  cases <- shared_fixture("provenance")$provenance_aside$cases
  # An empty fixture would make the loop below vacuously succeed.
  expect_gt(length(cases), 0)

  for (case in cases) {
    tag <- case$tag %||% NA_character_
    aside <- provenance_aside(tag, include_cited = case$include_cited)

    if (!isTRUE(case$emits)) {
      expect_identical(aside, "", info = case$name)
      next
    }
    entry <- provenance_display[[tag]]
    expect_match(
      aside,
      paste0('^<shiny-aside label="', entry$label, '"'),
      info = case$name
    )
    expect_match(aside, entry$body, fixed = TRUE, info = case$name)
  }
})

test_that("the rendered marker carries its icon from the asset bundle", {
  # Per-package, so out of the shared fixture: the URL is served by this
  # package's own dependency, and the Python renderer omits it until its UI
  # ships one.
  trusted <- provenance_aside("A")
  untrusted <- provenance_aside("C")

  expect_match(
    trusted,
    paste0('icon="', commons_icon_url("trusted-icon.svg"), '"'),
    fixed = TRUE
  )
  expect_match(
    untrusted,
    paste0('icon="', commons_icon_url("warning-icon.svg"), '"'),
    fixed = TRUE
  )
  expect_no_match(trusted, "data:image", fixed = TRUE)
  expect_no_match(untrusted, "data:image", fixed = TRUE)
  expect_match(trusted, "<commons-provenance-info", fixed = TRUE)
})
