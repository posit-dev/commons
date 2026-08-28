test_that("provenance information explains every visible state", {
  info <- provenance_info_control()
  query <- htmltools::tagQuery(htmltools::tags$div(info))

  expect_length(query$find(".commons-provenance-info")$selectedTags(), 1)
  trigger <- query$find(".commons-provenance-info-trigger")$selectedTags()
  expect_length(trigger, 1)
  expect_identical(
    trigger[[1]]$attribs[["aria-label"]],
    "How answer trust is determined"
  )

  text <- as.character(info)
  expect_match(text, "How answer trust is determined", fixed = TRUE)
  expect_match(text, "Verified answer", fixed = TRUE)
  expect_match(text, "Cited", fixed = TRUE)
  expect_match(text, "Untrusted", fixed = TRUE)
  expect_match(text, "No marker", fixed = TRUE)
  expect_match(
    text,
    "The custom calculation itself was not vetted.",
    fixed = TRUE
  )
  expect_match(text, "not equivalent to a Verified answer", fixed = TRUE)

  expect_match(text, commons_icon_url("trusted-icon.svg"), fixed = TRUE)
  expect_match(text, commons_icon_url("citation-mark.svg"), fixed = TRUE)
  expect_match(text, commons_icon_url("warning-icon.svg"), fixed = TRUE)
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

test_that("provenance_display uses R display copy", {
  display <- shared_fixture("provenance")$provenance_display$tags
  display$A$body <- paste(
    "This answer comes from a trusted calculation defined by",
    "your data team."
  )
  display$C$body <- paste(
    "This answer was not produced by a trusted calculation and has",
    "no verified supporting citation. AI can be wrong."
  )
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

test_that("provenance_aside renders A and C, nothing for B/NA", {
  trusted <- provenance_aside("A")
  untrusted <- provenance_aside("C")

  expect_match(trusted, '^<shiny-aside label="Verified answer"')
  expect_match(
    trusted,
    paste0('icon="', commons_icon_url("trusted-icon.svg"), '"'),
    fixed = TRUE
  )
  expect_no_match(trusted, "data:image", fixed = TRUE)
  expect_match(trusted, "commons-provenance-info-trigger", fixed = TRUE)
  expect_match(trusted, "How answer trust is determined", fixed = TRUE)

  expect_match(untrusted, '^<shiny-aside label="Untrusted"')
  expect_match(
    untrusted,
    paste0('icon="', commons_icon_url("warning-icon.svg"), '"'),
    fixed = TRUE
  )
  expect_no_match(untrusted, "data:image", fixed = TRUE)

  expect_identical(provenance_aside("B"), "")
  expect_identical(provenance_aside(NA_character_), "")

  cited <- provenance_aside("B", include_cited = TRUE)
  expect_match(cited, '^<shiny-aside label="Cited"')
  expect_match(cited, "verified against a trusted source", fixed = TRUE)
})
