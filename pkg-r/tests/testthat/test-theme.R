chat_theme_fixture <- shared_fixture("chat-theme")$chat_theme

test_that("the theme layers the shared Sass variables", {
  expected <- chat_theme_fixture$variables
  expect_gt(length(expected), 0L)
  values <- bslib::bs_get_variables(commons_theme(), names(expected))
  expect_identical(as.list(values), expected)
})

test_that("the theme starts from the shared preset", {
  preset <- bslib::bs_get_variables(commons_theme(), "bslib-preset-name")
  expect_identical(unname(preset), chat_theme_fixture$preset)
})

test_that("a variable argument beats a shared default", {
  override <- chat_theme_fixture$override
  theme <- rlang::exec(
    commons_theme,
    !!override$variable := override$value
  )
  expect_identical(
    unname(bslib::bs_get_variables(theme, override$variable)),
    override$value
  )
})
