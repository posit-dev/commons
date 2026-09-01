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

scan_chunks <- function(chunks, corpus) {
  scanner <- citation_scanner(corpus)
  fed <- vapply(chunks, scanner$feed, character(1), USE.NAMES = FALSE)
  list(
    text = paste0(paste(fed, collapse = ""), scanner$finish()),
    decisions = scanner$decisions()
  )
}

# {{pad}} keeps the cap cases small on disk: the fixture states the body length
# it wants and the runner builds the filler.
citation_scan_padding <- function(case, text) {
  if (is.null(case$pad)) {
    return("")
  }
  after_open <- sub(".*?<commons-citation>", "", text)
  body <- sub("</commons-citation>.*", "", after_open)
  strrep(
    case$pad$char,
    case$pad$citation_body_length - nchar(body) + nchar("{{pad}}")
  )
}

# The two packages resolve different icon URLs, so the fixture leaves each
# aside to the package reading it and pins every other character exactly.
citation_scan_expected <- function(case, corpus, padding) {
  expected <- gsub("{{pad}}", padding, case$expected_text, fixed = TRUE)
  for (i in seq_along(case$asides)) {
    aside <- case$asides[[i]]
    html <- render_citation_aside(
      aside$quote,
      gsub("{{pad}}", padding, aside$explanation, fixed = TRUE),
      corpus
    )$html
    expected <- gsub(
      paste0("{{aside:", i - 1L, "}}"),
      html,
      expected,
      fixed = TRUE
    )
  }
  expected
}

# Chunk invariance is a property of every case, not a case of its own, so each
# one is fed whole, at the fixture's own boundaries, and at every boundary a
# short text has.
citation_scan_chunkings <- function(text, chunks, exhaustive_max) {
  chunkings <- list("the whole text" = text)
  if (length(chunks) > 1) {
    chunkings[["the fixture's feed boundaries"]] <- chunks
  }
  if (nchar(text) <= exhaustive_max) {
    chars <- strsplit(text, "", fixed = TRUE)[[1]]
    chunkings[["one character at a time"]] <- chars
    for (at in seq_len(nchar(text) - 1L)) {
      chunkings[[paste("a split at", at)]] <- c(
        substr(text, 1, at),
        substr(text, at + 1L, nchar(text))
      )
    }
  }
  chunkings
}

as_json_list <- function(x) {
  jsonlite::fromJSON(
    jsonlite::toJSON(x, auto_unbox = TRUE),
    simplifyVector = FALSE
  )
}

test_that("the streaming scanner matches the shared cases", {
  spec <- shared_fixture("citations")$citation_scan
  expect_gte(length(spec$cases), 20)
  expect_identical(ELEMENT_BODY_CAP, as.integer(spec$element_body_cap))

  for (case in spec$cases) {
    corpus <- spec$corpora[[case$corpus]]
    text <- gsub("{{split}}", "", case$text, fixed = TRUE)
    padding <- citation_scan_padding(case, text)
    text <- gsub("{{pad}}", padding, text, fixed = TRUE)
    chunks <- strsplit(
      gsub("{{pad}}", padding, case$text, fixed = TRUE),
      "{{split}}",
      fixed = TRUE
    )[[1]]
    expected <- citation_scan_expected(case, corpus, padding)

    chunkings <- citation_scan_chunkings(
      text,
      chunks,
      spec$exhaustive_split_max_chars
    )
    for (how in names(chunkings)) {
      got <- scan_chunks(chunkings[[how]], corpus)
      info <- paste0(case$name, ", fed ", how)
      expect_identical(got$text, expected, info = info)
      expect_identical(as_json_list(got$decisions), case$decisions, info = info)
    }
  }
})

test_that("each feed emits the shared held-back cases", {
  cases <- shared_fixture("citations")$citation_holdback$cases
  expect_gt(length(cases), 0)

  corpus <- list(list(
    label = "documentation",
    kind = "prose",
    text = "Canopy cover is always acre-weighted for reporting."
  ))

  for (case in cases) {
    scanner <- citation_scanner(corpus)
    emitted <- vapply(
      case$chunks,
      function(chunk) scanner$feed(chunk),
      character(1),
      USE.NAMES = FALSE
    )
    expect_identical(as.list(emitted), case$emitted, info = case$name)
    expect_identical(scanner$finish(), case$flushed, info = case$name)
  }
})

test_that("an oversized unclosed citation keeps only a bounded close-tag suffix", {
  # Memory, not projection: the shared cases pin that nothing is emitted, and
  # this pins that nothing is retained while waiting for a close tag.
  corpus <- list(list(
    label = "documentation",
    kind = "prose",
    text = "Canopy cover is always acre-weighted for reporting."
  ))
  scanner <- citation_scanner(corpus)

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
