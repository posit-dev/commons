# The served assets have a single source at the repository root; this package
# ships a generated copy because an installed package cannot reach outside its
# own directory. Run scripts/sync-shared.sh after editing www/.
test_that("the shipped browser assets match the root source", {
  root <- test_path("..", "..", "..", "www")
  skip_if_not(dir.exists(root), "not a source checkout")

  shipped <- test_path("..", "..", "inst", "www")
  contents <- function(dir) setdiff(list.files(dir, recursive = TRUE), "README.md")

  expect_setequal(contents(shipped), contents(root))

  for (rel in contents(root)) {
    from <- file.path(root, rel)
    to <- file.path(shipped, rel)
    expect_equal(
      readBin(to, "raw", file.size(to)),
      readBin(from, "raw", file.size(from)),
      info = rel
    )
  }
})
