# Sharing's markup, titles, footer, and manifest are cross-language
# contracts: the cases live in tests/shared/share.json. Do not restate a case
# here; add it to the fixture.

share_script <- function() {
  read_utf8(system.file("www", "commons-share", "commons-share.js", package = "commons"))
}

# `data-output-input` is read in script as `dataset.outputInput`.
dataset_name <- function(attribute) {
  name <- sub("^data-", "", attribute)
  gsub("-([a-z])", "\\U\\1", name, perl = TRUE)
}

test_that("wrapped outputs follow the shared fixture", {
  spec <- shared_fixture("share")$markup
  expect_gt(length(spec$wrap$cases), 0)

  for (case in spec$wrap$cases) {
    html <- share_wrap(case$html, case$kind, case$title)
    id <- regmatches(html, regexpr("(?<=data-commons-share=\")[^\"]+", html, perl = TRUE))
    expect_match(id, spec$id_pattern, label = case$name)
    expect_identical(html, gsub("{id}", id, case$expected, fixed = TRUE), label = case$name)
  }

  script <- share_script()
  expect_match(script, "[data-commons-share]", fixed = TRUE)
  for (attribute in spec$wrap$script_reads) {
    expect_match(script, paste0("dataset.", dataset_name(attribute)), fixed = TRUE)
  }
})

test_that("share controls carry what the script reads", {
  spec <- shared_fixture("share")$markup$controls
  expect_gt(length(spec$cases), 0)
  person <- list(guid = "u1", type = "user", name = "Ada", detail = "ada@example.com")
  rendered <- list(
    config = share_config_tag("output"),
    pick = share_results_ui(list(person), "add"),
    remove = share_people_ui(NULL, list(person), "remove"),
    update = share_status_ui(list(text = "Changed.", update = TRUE), "update"),
    copy = share_copy_button("https://connect.example.com/x/", "copy")
  )
  script <- share_script()

  for (case in spec$cases) {
    html <- as.character(rendered[[case$name]])
    tag <- regmatches(
      html,
      regexpr(sprintf("<[a-z]+[^>]*class=\"[^\"]*\\b%s\\b[^\"]*\"[^>]*>", case$class), html)
    )
    expect_length(tag, 1)
    expect_match(script, paste0(".", case$class), fixed = TRUE, label = case$name)
    for (attribute in case$attributes) {
      expect_match(tag, paste0(attribute, "=\""), fixed = TRUE, label = case$name)
      expect_match(script, paste0("dataset.", dataset_name(attribute)), fixed = TRUE, label = case$name)
    }
  }
})

test_that("shared titles follow the shared fixture", {
  spec <- shared_fixture("share")$titles
  expect_gt(length(spec$connect$cases), 0)

  for (case in spec$connect$cases) {
    if (!is.null(case$`repeat`)) {
      title <- share_title(strrep(case$`repeat`$text, case$`repeat`$times))
      expect_identical(nchar(title), as.integer(case$expected_chars), label = case$name)
    } else {
      expect_identical(share_title(case$input), case$expected, label = case$name)
    }
  }
  for (case in spec$fallback$cases) {
    expect_identical(share_fallback_title(case$app_title, case$noun), case$expected)
  }
  for (case in spec$clean$cases) {
    expect_identical(share_clean_title(case$input), case$expected, label = case$name)
  }
  for (case in spec$truncate$cases) {
    expect_identical(truncate_title(case$input, spec$truncate$max_chars), case$expected)
  }
})

test_that("the share footer follows the shared fixture", {
  spec <- shared_fixture("share")$footer
  expect_gt(length(spec$cases), 0)

  for (case in spec$cases) {
    expect_identical(
      share_footer_html(case$app, as.Date(case$date)),
      case$expected,
      label = case$name
    )
  }
})

test_that("a static bundle's manifest follows the shared fixture", {
  spec <- shared_fixture("share")$manifest
  expect_gt(length(spec$files), 0)
  dir <- withr::local_tempdir()
  for (path in names(spec$files)) {
    dir.create(dirname(file.path(dir, path)), recursive = TRUE, showWarnings = FALSE)
    writeBin(charToRaw(spec$files[[path]]), file.path(dir, path))
  }

  write_static_manifest(dir)

  manifest <- jsonlite::read_json(file.path(dir, "manifest.json"))
  expect_identical(manifest[c("version", "metadata")], spec$expected[c("version", "metadata")])
  expect_identical(manifest$files[order(names(manifest$files))], spec$expected$files[order(names(spec$expected$files))])
})
