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

  expect_match(untrusted, '^<shiny-aside label="Untrusted"')
  expect_match(
    untrusted,
    paste0('icon="', commons_icon_url("warning-icon.svg"), '"'),
    fixed = TRUE
  )
  expect_no_match(untrusted, "data:image", fixed = TRUE)

  expect_identical(provenance_aside("B"), "")
  expect_identical(provenance_aside(NA_character_), "")
})
