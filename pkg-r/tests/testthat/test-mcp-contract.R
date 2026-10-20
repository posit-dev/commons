test_that("shared MCP exchanges use R's provenance classifier", {
  contract <- shared_fixture("mcp-contract")
  expect_gt(length(contract$exchanges), 0)
  expect_gt(length(contract$examples), 0)
  tags <- setNames(
    lapply(contract$examples, \(case) case$envelope$commons$provenance_tag),
    vapply(contract$examples, \(case) case$envelope$commons$tool_id, character(1))
  )
  for (case in contract$exchanges) {
    received <- unlist(tags[unlist(case$tools)])
    if (!is.null(case$expected_input_tags)) {
      expect_identical(unname(received), unlist(case$expected_input_tags))
    }
    expected <- if (is.null(case$expected_tag)) NA_character_ else case$expected_tag
    expect_identical(derive_provenance_tag(received, case$verified), expected)
  }
})
