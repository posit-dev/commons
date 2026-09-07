# The sample-summary contract both packages consume. The Python suite runs
# the same cases from the same file. See tests/shared/README.md.

sample_summary_spec <- function() {
  shared_fixture("sample-summary")
}

# The fixture's declarative column data as the vector R describes. A null
# stands for a missing value, and every type keeps its own NA so the column
# stays typed even when every value is missing.
sample_summary_column <- function(spec) {
  values <- spec$values
  # A list column keeps its elements whole; every other type flattens to a
  # vector first, with a typed NA standing in for each null.
  if (identical(spec$type, "list")) {
    return(lapply(values, unlist))
  }
  na <- switch(
    spec$type,
    integer = NA_integer_,
    double = NA_real_,
    boolean = NA,
    NA_character_
  )
  flat <- vapply(values, function(value) if (is.null(value)) na else value, na)
  switch(
    spec$type,
    integer = as.integer(flat),
    double = as.numeric(flat),
    string = as.character(flat),
    boolean = as.logical(flat),
    date = as.Date(as.character(flat)),
    datetime_utc = as.POSIXct(as.character(flat), tz = "UTC"),
    datetime_naive = as.POSIXct(as.character(flat))
  )
}

# The case's own wording, with this package's type token in each line.
sample_summary_expected <- function(case) {
  lines <- vapply(case$columns, function(column) {
    sprintf(
      "* %s: %s",
      column$name,
      sub("{type}", column$tokens$r, column$line, fixed = TRUE)
    )
  }, character(1))
  paste(c(case$header, lines), collapse = "\n")
}

test_that("the sample summary matches the shared contract", {
  spec <- sample_summary_spec()
  # An empty fixture would enumerate no cases and the runner would pass.
  expect_gt(length(spec$cases), 0)

  for (case in spec$cases) {
    columns <- lapply(case$columns, sample_summary_column)
    names(columns) <- vapply(case$columns, function(one) one$name, character(1))
    # A list column has to be attached after construction, or data.frame()
    # spreads it into one column per element.
    scalars <- columns[!vapply(columns, is.list, logical(1))]
    df <- if (length(scalars)) {
      as.data.frame(scalars, stringsAsFactors = FALSE)
    } else {
      data.frame()
    }
    for (name in setdiff(names(columns), names(scalars))) {
      df[[name]] <- columns[[name]]
    }
    df <- df[names(columns)]

    expect_identical(
      as.character(ellmer::df_schema(df, max_cols = ncol(df))),
      sample_summary_expected(case),
      info = case$name
    )
  }
})

test_that("describe_table introduces the summary with the shared heading", {
  spec <- sample_summary_spec()
  source <- test_source()

  body <- describe_table_tool(source, "sales")@value

  expect_match(
    body,
    paste0(spec$heading, "\n\nA data frame with"),
    fixed = TRUE
  )
})
