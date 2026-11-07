chat_theme_fixture <- shared_fixture("chat-theme")$chat_theme

test_that("the theme layers the shared Sass variables", {
  expected <- chat_theme_fixture$variables
  expect_gt(length(expected), 0L)
  values <- bslib::bs_get_variables(commons_theme(), names(expected))
  expect_identical(as.list(values), expected)
})

test_that("the theme starts from the shared preset", {
  # bslib exports no reader for a theme's preset.
  preset <- bslib:::theme_preset_info(commons_theme())
  expect_identical(preset$name, chat_theme_fixture$preset)
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
