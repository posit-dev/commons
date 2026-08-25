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

test_that("provenance_display matches the shared copy word for word", {
  display <- shared_fixture("provenance")$provenance_display$tags
  expect_setequal(names(display), names(provenance_display))

  for (tag in names(display)) {
    entry <- provenance_display[[tag]]
    expected <- display[[tag]]
    expect_identical(entry$label, expected$label, info = tag)
    expect_identical(entry$body, expected$body, info = tag)
    expect_identical(entry$icon, expected$icon, info = tag)
    expect_identical(entry$dot_class, expected$dot_class, info = tag)
  }
})

test_that("provenance_aside renders A and C, nothing for B/NA", {
  trusted <- provenance_aside("A")
  untrusted <- provenance_aside("C")

  expect_match(trusted, '^<shiny-aside label="Verified answer"')
  expect_match(
    trusted,
    'icon="commons-icons/trusted-icon.svg"',
    fixed = TRUE
  )
  expect_no_match(trusted, "data:image", fixed = TRUE)

  expect_match(untrusted, '^<shiny-aside label="Untrusted"')
  expect_match(
    untrusted,
    'icon="commons-icons/warning-icon.svg"',
    fixed = TRUE
  )
  expect_no_match(untrusted, "data:image", fixed = TRUE)

  expect_identical(provenance_aside("B"), "")
  expect_identical(provenance_aside(NA_character_), "")
})
