# traces/python/ and traces/r/ each hold a trace one agent wrote, and what a
# reader must make of it. See pkg-py/tests/_trace_fixture.py and
# trace-fixture.R.

trace_contents <- function(turns, class) {
  contents <- unlist(
    lapply(turns, function(turn) turn@contents),
    recursive = FALSE
  )
  Filter(function(content) S7::S7_inherits(content, class), contents)
}

expect_trace_reads_as_expected <- function(writer) {
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  expected <- shared_fixture(file.path("traces", writer, "expected"))
  expect_gt(length(expected$conversations), 0)

  trajectories <- trajectory_read(
    test_path("fixtures", "shared", "traces", writer)
  )

  expect_length(trajectories, length(expected$conversations))
  for (i in seq_along(expected$conversations)) {
    want <- expected$conversations[[i]]
    conversation <- trajectories[[i]]
    turns <- conversation$turns

    expect_identical(
      vapply(turns, function(turn) turn@role, character(1)),
      unlist(want$roles)
    )

    if (!is.null(want$tool)) {
      requests <- Filter(
        function(request) identical(request@name, want$tool$name),
        trace_contents(turns, ellmer::ContentToolRequest)
      )
      expect_length(requests, 1)
      linked <- Filter(
        function(result) identical(result@request, requests[[1]]),
        trace_contents(turns, ellmer::ContentToolResult)
      )
      expect_length(linked, if (isTRUE(want$tool$linked)) 1 else 0)
    } else {
      expect_length(trace_contents(turns, ellmer::ContentToolRequest), 0)
    }

    provenance <- attr(turns, "provenance")
    expect_length(provenance, length(want$exchanges))
    for (j in seq_along(want$exchanges)) {
      exchange <- want$exchanges[[j]]
      expect_identical(
        provenance[[j]]$provenance_tag,
        exchange$provenance_tag %||% NA_character_
      )
      expect_identical(
        vapply(
          provenance[[j]]$citation_decisions,
          function(decision) decision$status,
          character(1)
        ),
        as.character(unlist(exchange$decision_statuses))
      )
    }

    expect_identical(conversation$user, NA_character_)
  }
}

test_that("trajectory_read() reads the trace the Python agent wrote", {
  expect_trace_reads_as_expected("python")
})

test_that("trajectory_read() reads the trace the R agent wrote", {
  expect_trace_reads_as_expected("r")
})

prose <- "<prose>"

mask_descriptions <- function(x) {
  if (!is.list(x)) {
    return(x)
  }
  if (is.character(x[["description"]])) {
    x[["description"]] <- prose
  }
  x[] <- lapply(x, mask_descriptions)
  x
}

as_json <- function(x) {
  as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null"))
}

masked_attribute <- function(key, value, ordinal) {
  switch(
    key,
    "gen_ai.conversation.id" = ordinal(value),
    "gen_ai.system_instructions" = as_json(lapply(
      jsonlite::fromJSON(value, simplifyVector = FALSE),
      function(part) {
        if (is.character(part[["content"]])) part[["content"]] <- prose
        part
      }
    )),
    "gen_ai.tool.description" = prose,
    "gen_ai.tool.definitions" = as_json(mask_descriptions(
      jsonlite::fromJSON(value, simplifyVector = FALSE)
    )),
    value
  )
}

timing_attributes <- c(
  "gen_ai.response.time_to_first_chunk",
  "gen_ai.invoke_agent.duration"
)

# The spans in file order, keeping only the fields commons and the readers
# use, with what varies between runs replaced. Other span fields, such as
# flags and kind, belong to the SDK and are not compared.
normalized_trace <- function(path) {
  ordinals <- character()
  ordinal <- function(value) {
    if (!value %in% names(ordinals)) {
      ordinals[[value]] <<- paste0("#", length(ordinals) + 1L)
    }
    ordinals[[value]]
  }

  spans <- list()
  for (line in readLines(path, warn = FALSE)) {
    envelope <- jsonlite::fromJSON(line, simplifyVector = FALSE)
    for (resource in envelope$resourceSpans) {
      for (scope_spans in resource$scopeSpans) {
        scope <- scope_spans$scope$name
        if (startsWith(scope, "org.r-dbi.")) {
          next
        }
        for (span in scope_spans$spans) {
          ids <- lapply(
            c(trace = "traceId", span = "spanId", parent = "parentSpanId"),
            function(key) {
              if (nzchar(span[[key]] %||% "")) ordinal(span[[key]])
            }
          )
          kept <- Filter(
            function(attribute) !attribute$key %in% timing_attributes,
            span$attributes
          )
          attributes <- lapply(kept, function(attribute) {
            value <- attribute$value$stringValue
            if (!is.null(value)) {
              attribute$value$stringValue <- masked_attribute(
                attribute$key,
                value,
                ordinal
              )
            }
            attribute
          })
          spans[[length(spans) + 1L]] <- list(
            scope = scope,
            name = span$name,
            ids = ids,
            attributes = attributes,
            # 2 is OTLP's error code. An SDK may leave a span that ended
            # without error unset or set it to ok.
            error = identical(span$status$code, 2L)
          )
        }
      }
    }
  }
  spans
}

test_that("the trace comparison ignores SDK fields and keeps an error", {
  normalized_span <- function(...) {
    path <- withr::local_tempfile(fileext = ".jsonl")
    span <- list(traceId = "t", spanId = "s", name = "x", ...)
    envelope <- list(resourceSpans = list(list(scopeSpans = list(
      list(scope = list(name = "commons"), spans = list(span))
    ))))
    writeLines(jsonlite::toJSON(envelope, auto_unbox = TRUE), path)
    normalized_trace(path)
  }
  plain <- normalized_span(flags = 1L, kind = 1L)
  expect_identical(
    normalized_span(flags = 3L, kind = 3L, status = list(code = 1L)),
    plain
  )
  expect_false(identical(
    normalized_span(flags = 1L, kind = 1L, status = list(code = 2L)),
    plain
  ))
})

test_that("the agent still writes the committed trace", {
  skip_on_cran()
  skip_if_not_installed("otelsdk")
  skip_if_ellmer_streaming_hooks_unavailable()

  written <- write_trace_fixture(withr::local_tempdir())
  taken <- Filter(
    function(case) isTRUE(case$read),
    shared_fixture("traces")$file_naming$cases
  )
  expect_true(basename(written) %in% vapply(taken, `[[`, character(1), "file"))

  committed <- test_path("fixtures", "shared", "traces", "r", basename(written))
  expect_true(file.exists(committed))
  expect_identical(trace_private_strings(committed), character())
  want <- normalized_trace(committed)
  expect_gt(length(want), 0)
  expect_identical(
    normalized_trace(written),
    want,
    info = paste0(
      "The agent no longer writes the committed trace. If the change is ",
      "intended, regenerate it from the repository root:\n\n",
      "  find tests/shared/traces/r -name '*.jsonl' -delete && cd pkg-r && ",
      "Rscript -e 'devtools::load_all(quiet = TRUE); ",
      "write_trace_fixture(\"../tests/shared/traces/r\")' && cd .. && ",
      "scripts/sync-shared.sh\n\n",
      "Then run the Python suite."
    )
  )
})

test_that("the privacy check finds a login name only as a path part or value", {
  path <- withr::local_tempfile(fileext = ".jsonl")
  writeLines('{"key":"service.name","value":{"stringValue":"same"}}', path)
  expect_identical(trace_private_strings(path, user = "key"), character())
  expect_identical(trace_private_strings(path, user = "sam"), character())

  writeLines('{"key":"process.owner","value":{"stringValue":"sam"}}', path)
  expect_identical(trace_private_strings(path, user = "sam"), ':"sam"')
  writeLines('{"key":"code.filepath","value":{"stringValue":"/home/sam/x.R"}}', path)
  expect_identical(trace_private_strings(path, user = "sam"), "/sam/")
})
