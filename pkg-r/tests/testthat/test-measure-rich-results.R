# What the model and the user get from a measure that returns a plot or a
# styled table is a cross-language contract: the cases live in
# tests/shared/measure-rich-results.json, and the Python suite runs the same
# ones. Do not restate a case here; add it to the fixture.

test_that("rich measure results follow the shared fixture", {
  skip_if_not_installed("ggplot2")
  skip_if_not_installed("gt")
  spec <- shared_fixture("measure-rich-results")
  tool <- spec$substitutions$r$tool
  expect_gt(length(spec$cases$cases), 0)

  for (case in spec$cases$cases) {
    value <- eval(parse(text = case$value$r))
    registry <- list(
      returned = measure(
        "returned",
        "A measure under test.",
        function() value,
        title = case$title
      )
    )
    store <- new_handle_store()
    res <- call_measure_tool(registry, "returned", "{}", handles = store)
    expect <- case$expect

    parts <- if (is.list(res@value)) res@value else list()
    text <- if (is.character(res@value)) {
      res@value
    } else {
      texts <- Filter(\(x) S7::S7_inherits(x, ellmer::ContentText), parts)
      paste(vapply(texts, \(x) x@text, character(1)), collapse = "\n\n")
    }
    images <- sum(vapply(
      parts,
      \(x) S7::S7_inherits(x, ellmer::ContentImageInline),
      logical(1)
    ))
    html <- as.character(res@extra$display$html)

    if (!is.null(expect$note)) {
      note <- gsub("{tool}", tool, spec$notes[[expect$note]], fixed = TRUE)
      expect_true(startsWith(text, note), label = case$name)
    }
    if (!is.null(expect$failure)) {
      failure <- gsub("{kind}", expect$failure, spec$notes$failure, fixed = TRUE)
      expect_match(text, failure, fixed = TRUE, label = case$name)
    }
    if (!is.null(expect$contains)) {
      expect_match(text, expect$contains, fixed = TRUE, label = case$name)
    }
    expect_identical(images, as.integer(expect$images), label = case$name)
    expect_match(html, expect$class, fixed = TRUE, label = case$name)
    if (isTRUE(expect$alt)) {
      alt <- gsub("{title}", case$title, spec$alt, fixed = TRUE)
      expect_match(html, sprintf('alt="%s"', alt), fixed = TRUE)
    }
    if (isTRUE(expect$frame_handle)) {
      expect_s3_class(get_handle(store, "r1"), "data.frame")
    }
    expect_identical(res@extra$commons_tag, "A")
    expect_identical(res@extra$display$open, TRUE)
  }
})
