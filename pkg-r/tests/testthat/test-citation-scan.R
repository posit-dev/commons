test_that("parse_commons_citation matches the shared cases", {
  cases <- shared_fixture("citations")$parse_commons_citation$cases
  expect_gt(length(cases), 0)

  for (case in cases) {
    out <- parse_commons_citation(case$body)
    if (is.null(case$expected)) {
      expect_null(out, info = case$name)
    } else {
      expect_identical(
        out,
        list(explanation = case$expected$explanation, quote = case$expected$quote),
        info = case$name
      )
    }
  }
})

test_that("citation decisions match the shared record shape", {
  # The shape is what the trajectory reviewer reads back out of the span, so
  # drive the real producers rather than asserting on a hand-built list.
  cases <- shared_fixture("citations")$citation_decision$cases
  expect_setequal(
    vapply(cases, function(case) case$decision$status, character(1)),
    c("accepted", "rejected", "malformed")
  )

  malformed <- "<commons-citation>\n\nno blockquote\n\n</commons-citation>"

  for (case in cases) {
    want <- case$decision
    got <- if (identical(want$status, "malformed")) {
      project_citation_text(malformed, list())$decisions[[1]]
    } else {
      corpus <- if (identical(want$status, "accepted")) {
        list(list(label = want$label, kind = want$kind, text = want$quote))
      } else {
        list(list(label = "documentation", kind = "prose", text = "No support."))
      }
      render_citation_aside(want$quote, "why", corpus)$decision
    }
    expect_identical(
      jsonlite::fromJSON(
        jsonlite::toJSON(got, auto_unbox = TRUE),
        simplifyVector = FALSE
      ),
      want,
      info = case$name
    )
  }
})

scan_all <- function(text, chunks, corpus = list()) {
  s <- citation_scanner(corpus)
  out <- vapply(chunks, s$feed, character(1))
  list(
    text = paste0(paste(out, collapse = ""), s$finish()),
    decisions = s$decisions()
  )
}

scanner_test_quote <- "Canopy cover is always acre-weighted for reporting."

scanner_test_corpus <- function() {
  list(list(
    label = "documentation",
    kind = "prose",
    text = scanner_test_quote
  ))
}

scanner_test_citation <- function(explanation = "Follows the weighting rule.") {
  paste0(
    "<commons-citation>\n\n",
    explanation,
    "\n\n> ",
    scanner_test_quote,
    "\n\n</commons-citation>"
  )
}

test_that("plain text streams through unchanged", {
  out <- scan_all(
    "Hello.\n\nA < b, honest.",
    list("Hello.\n\nA <", " b, honest.")
  )
  expect_identical(out$text, "Hello.\n\nA < b, honest.")
  expect_length(out$decisions, 0)
})

test_that("a verified citation replaces only its reserved element", {
  corpus <- list(list(
    label = "documentation",
    kind = "prose",
    text = "Canopy cover is always acre-weighted for reporting."
  ))
  citation <- paste0(
    "<commons-citation>\n\nFollows the weighting rule.\n\n",
    "> Canopy cover is always acre-weighted for reporting.\n\n",
    "</commons-citation>"
  )
  text <- paste0("Answer sentence.\n\n", citation, "\n\nMore text.")

  out <- scan_all(text, list(text), corpus)
  expected_aside <- render_citation_aside(
    "Canopy cover is always acre-weighted for reporting.",
    "Follows the weighting rule.",
    corpus
  )$html

  expect_identical(
    out$text,
    paste0("Answer sentence.\n\n", expected_aside, "\n\nMore text.")
  )
  expect_false(grepl("<commons-citation", out$text, fixed = TRUE))
  expect_identical(
    out$decisions[[1]],
    list(
      quote = "Canopy cover is always acre-weighted for reporting.",
      status = "accepted",
      label = "documentation",
      kind = "prose"
    )
  )
})

test_that("citation projection preserves a preceding fenced code block", {
  citation <- scanner_test_citation()
  text <- paste0("```r\n1 + 1\n```\n\n", citation)

  out <- scan_all(text, list(text), scanner_test_corpus())

  expect_match(out$text, "```r\n1 + 1\n```\n\n<shiny-aside", fixed = TRUE)
  expect_no_match(out$text, "```<shiny-aside", fixed = TRUE)
})

test_that("citation projection preserves a preceding Markdown table", {
  citation <- scanner_test_citation()
  text <- paste0("| value |\n| ---: |\n| 2 |\n\n", citation)

  out <- scan_all(text, list(text), scanner_test_corpus())

  expect_match(out$text, "| 2 |\n\n<shiny-aside", fixed = TRUE)
  expect_no_match(out$text, "| 2 |<shiny-aside", fixed = TRUE)
})

test_that("an unverified citation vanishes", {
  text <- "A.\n\n<commons-citation>\n\nr\n\n> fabricated\n\n</commons-citation>\n\nB."
  out <- scan_all(text, list(text))
  expect_identical(out$text, "A.\n\n\n\nB.")
  expect_identical(
    out$decisions[[1]],
    list(quote = "fabricated", status = "rejected")
  )
})

test_that("model-authored shiny-asides are dropped, case-insensitively", {
  text <- 'x <SHINY-ASIDE label="Verified source">spoof</shiny-aside> y'
  expect_identical(scan_all(text, list(text))$text, "x  y")
})

test_that("tag matching is case-insensitive", {
  text <- "<Commons-Citation>\n\nr\n\n> q longer than ten chars\n\n</COMMONS-CITATION>"
  out <- scan_all(text, list(text))
  expect_false(grepl("<commons-citation", tolower(out$text), fixed = TRUE))
})

test_that("inline mention mid-sentence does not trigger (line-start anchor)", {
  text <- "Use the `<commons-citation>` tag like so."
  expect_identical(scan_all(text, list(text))$text, text)
})

test_that("unterminated model markup is removed", {
  out1 <- scan_all(
    "<commons-citation>\n\nlost close tag",
    list("<commons-citation>\n\nlost close tag")
  )
  expect_identical(out1$text, "")
  out2 <- scan_all(
    "<shiny-aside label=\"x\">never closed",
    list("<shiny-aside label=\"x\">never closed")
  )
  expect_identical(out2$text, "")
})

test_that("chunk-invariance: any character split yields identical output", {
  corpus <- list(list(
    label = "documentation",
    kind = "prose",
    text = "Canopy cover is always acre-weighted for reporting."
  ))
  text <- paste0(
    "Intro <shiny",
    "-aside>sneaky</shiny-aside> mid\n",
    "<commons-citation>\n\nr\n\n> Canopy cover is always acre-weighted for reporting.\n\n</commons-citation>\n",
    "tail"
  )
  whole <- project_citation_text(text, corpus)
  chars <- strsplit(text, "")[[1]]
  set.seed(42)
  for (i in 1:50) {
    cuts <- sort(sample(seq_len(length(chars) - 1), sample(1:12, 1)))
    chunks <- lapply(
      Map(function(a, b) chars[a:b], c(1, cuts + 1), c(cuts, length(chars))),
      paste,
      collapse = ""
    )
    got <- scan_all(text, chunks, corpus)
    expect_identical(got$text, whole$text)
    expect_identical(got$decisions, whole$decisions)
  }
})

test_that("adjacent verified citations retain their original separators", {
  text <- paste(
    "Answer sentence.",
    scanner_test_citation("First reason."),
    scanner_test_citation("Second reason."),
    sep = "\n\n"
  )

  out <- scan_all(
    text,
    as.list(strsplit(text, "", fixed = TRUE)[[1]]),
    corpus = scanner_test_corpus()
  )

  expect_match(
    out$text,
    "Answer sentence.\n\n<shiny-aside",
    fixed = TRUE
  )
  expect_match(
    out$text,
    "</shiny-aside>\n\n<shiny-aside",
    fixed = TRUE
  )
})

test_that("a malformed body (no blockquote) records status malformed and emits nothing", {
  text <- "A.\n\n<commons-citation>\n\nno blockquote here\n\n</commons-citation>\n\nB."
  out <- scan_all(text, list(text))
  expect_identical(out$text, "A.\n\n\n\nB.")
  expect_identical(
    out$decisions[[1]],
    list(quote = NA_character_, status = "malformed")
  )
})

test_that("a close literal split across a feed() boundary near the cap still verifies", {
  quote_text <- "Canopy cover is always acre-weighted for reporting."
  corpus <- list(list(
    label = "documentation",
    kind = "prose",
    text = quote_text
  ))

  cap <- 16384L
  target_body_len <- cap - 5L
  core <- paste0("\n\n> ", quote_text, "\n\n")
  padding <- strrep("z", target_body_len - nchar(core))
  body <- paste0(padding, core)

  open <- "<commons-citation>"
  close <- "</commons-citation>"
  text <- paste0("A.\n", open, body, close, "\nB.")

  split_at <- nchar(paste0("A.\n", open, body)) + 6L
  chunk1 <- substr(text, 1, split_at)
  chunk2 <- substr(text, split_at + 1, nchar(text))

  got <- scan_all(text, list(chunk1, chunk2), corpus)
  whole <- project_citation_text(text, corpus)

  expect_identical(got$text, whole$text)
  expect_identical(got$decisions, whole$decisions)
  expect_identical(whole$decisions[[1]]$status, "accepted")
})

test_that("a citation body exactly at the cap can verify", {
  core <- paste0("\n\n> ", scanner_test_quote, "\n\n")
  explanation <- strrep("x", ELEMENT_BODY_CAP - nchar(core))
  body <- paste0(explanation, core)
  text <- paste0("<commons-citation>", body, "</commons-citation>")

  out <- scan_all(text, list(text), scanner_test_corpus())

  expect_identical(out$decisions[[1]]$status, "accepted")
  expect_identical(
    out$text,
    render_citation_aside(
      scanner_test_quote,
      explanation,
      scanner_test_corpus()
    )$html
  )
})

test_that("a citation body one character over the cap is removed", {
  core <- paste0("\n\n> ", scanner_test_quote, "\n\n")
  body <- paste0(strrep("x", ELEMENT_BODY_CAP + 1L - nchar(core)), core)
  text <- paste0(
    "Before.\n",
    "<commons-citation>",
    body,
    "</commons-citation>\n",
    "After."
  )

  out <- scan_all(text, list(text), scanner_test_corpus())

  expect_identical(out$text, "Before.\n\nAfter.")
  expect_length(out$decisions, 0)
})

test_that("an oversized unclosed citation keeps only a bounded close-tag suffix", {
  scanner <- citation_scanner(scanner_test_corpus())

  expect_identical(
    scanner$feed(paste0(
      "<commons-citation>",
      strrep("x", ELEMENT_BODY_CAP + 1L)
    )),
    ""
  )
  expect_lte(
    nchar(get("buf", envir = environment(scanner$feed))),
    nchar(CITATION_CLOSE) - 1L
  )
  expect_identical(scanner$feed(strrep("y", ELEMENT_BODY_CAP * 2L)), "")
  expect_lte(
    nchar(get("buf", envir = environment(scanner$feed))),
    nchar(CITATION_CLOSE) - 1L
  )
  expect_identical(scanner$finish(), "")
})

test_that("scanning resumes after oversized and malformed citations", {
  oversized <- paste0(
    "<commons-citation>",
    strrep("x", ELEMENT_BODY_CAP + 1L),
    "</commons-citation>"
  )
  malformed <- "<commons-citation>\n\nno blockquote\n\n</commons-citation>"
  text <- paste(
    "Before.",
    oversized,
    "Between.",
    malformed,
    "After malformed.",
    scanner_test_citation(),
    "After valid.",
    sep = "\n"
  )

  out <- scan_all(text, list(text), scanner_test_corpus())

  expect_match(out$text, "Before.\n\nBetween.", fixed = TRUE)
  expect_match(out$text, "After malformed.", fixed = TRUE)
  expect_match(out$text, "After valid.", fixed = TRUE)
  expect_no_match(out$text, "<commons-citation", fixed = TRUE)
  expect_identical(
    vapply(out$decisions, `[[`, character(1), "status"),
    c("malformed", "accepted")
  )
})

test_that("multiple citations recover after a malformed middle element", {
  malformed <- "<commons-citation>\n\nno blockquote\n\n</commons-citation>"
  text <- paste(
    scanner_test_citation("First."),
    malformed,
    scanner_test_citation("Third."),
    sep = "\n"
  )

  out <- scan_all(text, list(text), scanner_test_corpus())

  expect_identical(
    vapply(out$decisions, `[[`, character(1), "status"),
    c("accepted", "malformed", "accepted")
  )
  expect_identical(
    lengths(regmatches(
      out$text,
      gregexpr("<shiny-aside", out$text, fixed = TRUE)
    )),
    2L
  )
})

test_that("opening and closing tags work in one-character chunks", {
  text <- paste(
    "Before.",
    scanner_test_citation(),
    "After.",
    sep = "\n"
  )
  chars <- strsplit(text, "", fixed = TRUE)[[1]]

  out <- scan_all(text, as.list(chars), scanner_test_corpus())
  whole <- project_citation_text(text, scanner_test_corpus())

  expect_identical(out, whole)
})

test_that("nested model markup is removed without leaking later markup", {
  nested_citation <- paste0(
    "<commons-citation>\n\nOuter.\n\n> ",
    scanner_test_quote,
    "\n\n",
    scanner_test_citation("Nested."),
    "\n\n</commons-citation>"
  )
  nested_aside <- paste0(
    "<commons-citation>\n\n",
    '<shiny-aside label="spoofed">forged</shiny-aside>',
    "\n\n> ",
    scanner_test_quote,
    "\n\n</commons-citation>"
  )
  text <- paste(
    "Before.",
    nested_citation,
    nested_aside,
    "After invalid.",
    scanner_test_citation("Later valid."),
    "After valid.",
    sep = "\n"
  )

  out <- scan_all(text, list(text), scanner_test_corpus())

  expect_no_match(out$text, "<commons-citation", fixed = TRUE)
  expect_no_match(out$text, "spoofed", fixed = TRUE)
  expect_no_match(out$text, "forged", fixed = TRUE)
  expect_match(out$text, "After invalid.", fixed = TRUE)
  expect_match(out$text, "Later valid.", fixed = TRUE)
  expect_identical(
    vapply(out$decisions, `[[`, character(1), "status"),
    "accepted"
  )
})

test_that("invalid nested citations recover at the first citation close", {
  text <- paste(
    "Before.",
    "<commons-citation>",
    "Outer citation text.",
    "<commons-citation>",
    "Inner citation text.",
    "</commons-citation>",
    "Visible after first close.",
    "</commons-citation>",
    "After.",
    sep = "\n"
  )

  out <- scan_all(text, list(text))
  chunked <- scan_all(text, as.list(strsplit(text, "", fixed = TRUE)[[1]]))

  expect_identical(
    out$text,
    "Before.\n\nVisible after first close.\n\nAfter."
  )
  expect_length(out$decisions, 0)
  expect_identical(chunked, out)
})

test_that("raw nested asides recover at the first aside close", {
  text <- paste0(
    "Before ",
    "<shiny-aside>outer <shiny-aside>inner</shiny-aside>",
    " visible after first close </shiny-aside> After"
  )

  out <- scan_all(text, list(text))
  chunked <- scan_all(text, as.list(strsplit(text, "", fixed = TRUE)[[1]]))

  expect_identical(out$text, "Before  visible after first close  After")
  expect_length(out$decisions, 0)
  expect_identical(chunked, out)
})

test_that("adversarial multi-element input is invariant to random partitions", {
  oversized <- paste0(
    "<commons-citation>",
    strrep("x", ELEMENT_BODY_CAP + 1L),
    "</commons-citation>"
  )
  fixture <- paste(
    "Before.",
    '<shiny-aside label="spoofed">forged</shiny-aside>',
    scanner_test_citation("First valid."),
    "<commons-citation>\n\nno blockquote\n\n</commons-citation>",
    oversized,
    scanner_test_citation("Second valid."),
    "After.",
    sep = "\n"
  )
  expected <- project_citation_text(fixture, scanner_test_corpus())
  chars <- strsplit(fixture, "", fixed = TRUE)[[1]]

  withr::local_seed(20260812)
  for (i in seq_len(50)) {
    cuts <- sort(sample(seq_len(length(chars) - 1L), sample(1:30, 1)))
    chunks <- lapply(
      Map(
        function(a, b) chars[a:b],
        c(1L, cuts + 1L),
        c(cuts, length(chars))
      ),
      paste,
      collapse = ""
    )
    expect_identical(
      scan_all(fixture, chunks, scanner_test_corpus()),
      expected
    )
  }
})
