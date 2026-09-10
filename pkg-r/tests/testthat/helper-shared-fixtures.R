# Read a cross-language fixture from tests/shared/.
#
# testthat needs its fixtures inside the package and an installed package
# cannot reach the repository root, so the R suite reads a generated copy
# rather than the source. Run scripts/sync-shared.sh after editing
# tests/shared/; CI fails when this copy is stale.
shared_fixture <- function(name) {
  path <- test_path("fixtures", "shared", paste0(name, ".json"))
  if (!file.exists(path)) {
    cli::cli_abort(c(
      "No synced copy of shared fixture {.val {name}} at {.path {path}}.",
      i = "Run {.code scripts/sync-shared.sh} from the repository root."
    ))
  }
  jsonlite::fromJSON(path, simplifyVector = FALSE)
}

# Build the ellmer type a fixture spec describes. Shared by every runner
# whose fixture declares measure arguments (measure-schema.json,
# citation-corpus.json).
fixture_scalar_type <- function(kind, description = "", required = TRUE) {
  switch(
    kind,
    integer = ellmer::type_integer(description, required = required),
    number = ellmer::type_number(description, required = required),
    boolean = ellmer::type_boolean(description, required = required),
    ellmer::type_string(description, required = required)
  )
}

fixture_type <- function(arg) {
  required <- isTRUE(arg$required)
  if (identical(arg$type, "enum")) {
    return(ellmer::type_enum(
      values = unlist(arg$values),
      description = arg$description,
      required = required
    ))
  }
  if (identical(arg$type, "array")) {
    items <- if (identical(arg$items$type, "enum")) {
      ellmer::type_enum(values = unlist(arg$items$values))
    } else {
      fixture_scalar_type(arg$items$type)
    }
    return(ellmer::type_array(
      items = items,
      description = arg$description,
      required = required
    ))
  }
  fixture_scalar_type(arg$type, arg$description, required)
}

# Build a measure from a fixture spec. The injected arguments only have to
# exist as formals; measure() marks them as hidden from the model.
fixture_measure <- function(spec) {
  arguments <- list()
  for (arg in spec$arguments) {
    arguments[[arg$name]] <- fixture_type(arg)
  }
  formal_names <- c(names(arguments), unlist(spec$injected))
  fn <- as.function(c(
    stats::setNames(rep(list(quote(expr = )), length(formal_names)), formal_names),
    list(NULL)
  ))
  measure(spec$name, spec$description, fn, arguments = arguments)
}
