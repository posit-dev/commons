test_that("derive_provenance_tag follows the A/B/C rules", {
  expect_identical(derive_provenance_tag(c("A", "B"), verified = TRUE), "B")
  expect_identical(derive_provenance_tag(c("A", "B"), verified = FALSE), "C")
  expect_identical(derive_provenance_tag("A", verified = FALSE), "A")
  expect_identical(derive_provenance_tag(character(), FALSE), NA_character_)
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
