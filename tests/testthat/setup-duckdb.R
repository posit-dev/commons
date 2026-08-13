# duckdb >= 1.5.5 announces where it stores extensions/secrets unless a
# storage home is chosen explicitly; the announcement leaks into
# expect_snapshot() output. Match duckdb_connect()'s directory.
options(duckdb.home = file.path(tempdir(), "duckdb"))
