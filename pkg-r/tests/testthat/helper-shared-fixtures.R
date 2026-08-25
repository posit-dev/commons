# Read a cross-language fixture from tests/shared/.
#
# testthat needs its fixtures inside the package and an installed package
# cannot reach the repository root, so the R suite reads a generated copy
# rather than the source. Run scripts/sync-shared-fixtures.sh after editing
# tests/shared/; CI fails when this copy is stale.
shared_fixture <- function(name) {
  path <- test_path("fixtures", "shared", paste0(name, ".json"))
  if (!file.exists(path)) {
    cli::cli_abort(c(
      "No synced copy of shared fixture {.val {name}} at {.path {path}}.",
      i = "Run {.code scripts/sync-shared-fixtures.sh} from the repository root."
    ))
  }
  jsonlite::fromJSON(path, simplifyVector = FALSE)
}
