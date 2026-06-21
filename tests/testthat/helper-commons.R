test_sales <- function() {
  data.frame(
    order_id = sprintf("o%02d", 1:6),
    revenue = c(500, 900, 1200, 300, 2000, 750),
    region = c("EMEA", "Americas", "EMEA", "APAC", "Americas", "EMEA"),
    product_line = c(
      "Platform",
      "Services",
      "Platform",
      "Training",
      "Platform",
      "Services"
    ),
    rep = c("Ada", "Ada", "Bo", "Cy", "Bo", "Ada"),
    stringsAsFactors = FALSE
  )
}

test_source <- function() {
  data_source(sales = test_sales())
}

test_client <- function() {
  ellmer::chat_anthropic(model = "claude-sonnet-4-5")
}

test_agent <- function(
  context = NULL,
  log_dir = withr::local_tempdir(.local_envir = parent.frame())
) {
  commons(
    test_client(),
    source = test_source(),
    context = context,
    log_dir = log_dir
  )
}

count_measure_tool <- function() {
  ellmer::tool(
    function(region = NULL, revenue_under = NULL) {
      df <- test_sales()
      if (!is.null(region)) {
        df <- df[df$region %in% region, ]
      }
      if (!is.null(revenue_under)) {
        df <- df[df$revenue < revenue_under, ]
      }
      nrow(df)
    },
    "Count orders, optionally filtered by region and a revenue ceiling.",
    arguments = list(
      region = ellmer::type_array(
        ellmer::type_enum(c("Americas", "APAC", "EMEA")),
        required = FALSE
      ),
      revenue_under = ellmer::type_number(required = FALSE)
    ),
    name = "order_count"
  )
}
