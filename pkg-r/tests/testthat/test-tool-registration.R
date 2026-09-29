# The tool registration and description contract both packages consume.
# The Python suite runs the same cases from the same file. See
# tests/shared/README.md.

tool_registration_spec <- function() {
  shared_fixture("tool-registration")
}

tool_registration_cases <- function(spec, section) {
  cases <- spec[[section]]$cases
  # An empty section would enumerate no cases and the runner would pass.
  expect_gt(length(cases), 0)
  cases
}

fixture_definition_rows <- function(spec, source) {
  names <- if (is.null(spec$count)) {
    spec$name
  } else {
    sprintf("%s%d", spec$name, seq_len(spec$count))
  }
  data.frame(
    name = names,
    table = spec$table,
    source = source,
    kind = spec$kind,
    label = spec$label %||% NA_character_,
    stringsAsFactors = FALSE
  )
}

# A source with the frames every shape shares, made catalog-searchable when
# the shape says its listing is too broad to name in the prompt.
fixture_tool_source <- function(searchable) {
  source <- test_source()
  if (searchable) {
    state <- data_source_state(source)
    state$manifest <- new_catalog_manifest(
      list(sales = list(
        id = state$table_ids$sales,
        kind = "table",
        description = "Booked sales activity."
      )),
      TRUE
    )
    state$manifest$searchable <- TRUE
  }
  source
}

fixture_tools <- function(spec, shape_name) {
  shape <- spec$shapes$values[[shape_name]]
  source_names <- unlist(shape$sources)
  broad <- unlist(shape$catalog_searchable) %||% character()
  sources <- stats::setNames(
    lapply(source_names, function(name) fixture_tool_source(name %in% broad)),
    source_names
  )

  registry <- lapply(shape$measures, function(one) {
    measure(one$name, one$description, function() 0L)
  })
  names(registry) <- vapply(shape$measures, function(one) one$name, character(1))

  rows <- lapply(
    shape$definitions,
    fixture_definition_rows,
    source = source_names[[1]]
  )
  defs <- if (length(rows)) {
    do.call(rbind, rows)
  } else {
    data.frame(
      name = character(),
      table = character(),
      source = character(),
      kind = character(),
      label = character(),
      stringsAsFactors = FALSE
    )
  }

  private <- list(
    sources = sources,
    registry = registry,
    definitions = list(defs = defs),
    semantic_models = semantic_models_registry(sources),
    calculations = list(),
    context_layer = NULL,
    handles = NULL,
    first_touch = NULL,
    injections = list(),
    measure_provenance = list(),
    citation_request = NULL,
    fn_sources = list(),
    worker = list(network = "none")
  )
  build_commons_tools(NULL, private)
}

test_that("tool registration matches the shared contract", {
  spec <- tool_registration_spec()
  execution <- unlist(spec$execution_tools)

  for (case in tool_registration_cases(spec, "registration")) {
    names <- vapply(fixture_tools(spec, case$shape), tool_name, character(1))
    # run_r is built here and run_python is built by its own owner in the
    # Python package, so neither is part of what the two agree on.
    expect_identical(
      setdiff(names, execution),
      unlist(case$tools),
      info = case$name
    )
  }
})

test_that("tool descriptions match the shared contract", {
  spec <- tool_registration_spec()

  for (case in tool_registration_cases(spec, "descriptions")) {
    tools <- fixture_tools(spec, case$shape)
    names <- vapply(tools, tool_name, character(1))
    expect_true(case$tool %in% names, info = case$name)
    expect_identical(
      tool_description(tools[[match(case$tool, names)]]),
      case$text,
      info = case$name
    )
  }
})

test_that("every shape in the fixture is used", {
  spec <- tool_registration_spec()
  used <- unique(unlist(lapply(
    c("registration", "descriptions"),
    function(section) {
      vapply(tool_registration_cases(spec, section), function(case) {
        case$shape
      }, character(1))
    }
  )))

  expect_setequal(used, names(spec$shapes$values))
})
