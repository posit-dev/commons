test_that("load_skill returns instructions without frontmatter", {
  tool <- tool_load_skill()

  res <- tool(name = "trust-system")
  expect_no_match(res@value, "description:", fixed = TRUE)
  expect_error(tool(name = "nonexistent"), "no skill named")
})
