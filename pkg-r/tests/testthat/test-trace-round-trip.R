# traces/python/ holds a trace the Python agent wrote, and what a reader must
# make of it. See pkg-py/tests/_trace_fixture.py.

trace_contents <- function(turns, class) {
  contents <- unlist(
    lapply(turns, function(turn) turn@contents),
    recursive = FALSE
  )
  Filter(function(content) S7::S7_inherits(content, class), contents)
}

test_that("trajectory_read() reads the trace the Python agent wrote", {
  withr::local_envvar(OTEL_EXPORTER_OTLP_TRACES_FILE = NA)
  expected <- shared_fixture(file.path("traces", "python", "expected"))
  expect_gt(length(expected$conversations), 0)

  trajectories <- trajectory_read(
    test_path("fixtures", "shared", "traces", "python")
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
})
