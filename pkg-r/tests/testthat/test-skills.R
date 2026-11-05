test_that("load_skill returns instructions without frontmatter", {
  tool <- tool_load_skill()

  res <- tool(name = "trust-system")
  expect_no_match(res@value, "description:", fixed = TRUE)
  expect_error(tool(name = "nonexistent"), "no skill named")
})

test_that("skills are offered beside the tools the shared cases say", {
  for (case in shared_fixture("skills")$cases) {
    expect_identical(
      names(builtin_skills(as.character(unlist(case$tools)))),
      as.character(unlist(case$offered)),
      info = case$name
    )
  }
})
