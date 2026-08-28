library(bslib)
library(shiny)

pkgload::load_all()

semantic_view <- DBI::Id(
  catalog = "MY_TEST_DB",
  schema = "COMMONS_EXAMPLE",
  table = "SALES_SEMANTIC"
)

greeting <- paste(
  "Explore sales from a Snowflake semantic view.",
  "\n\nTry this question:\n\n",
  "- <span class='suggestion'>What is total revenue by region?</span>"
)

ui <- shinychat::page_chat(
  "Snowflake semantic view",
  id = "chat",
  greeting = greeting,
  theme = commons_theme()
)

server <- function(input, output, session) {
  snowflake <- snowflakeauth::snowflake_connection()
  con <- DBI::dbConnect(
    odbc::snowflake(),
    account = "DULOFTF-POSIT_SOFTWARE_PBC_DEV_AZURE",
    uid = snowflake$user,
    authenticator = "externalbrowser",
    role = "DEVELOPER",
    warehouse = "DEFAULT_WH",
    client_store_temporary_credential = "false"
  )
  session$onSessionEnded(function() DBI::dbDisconnect(con))

  identity <- DBI::dbGetQuery(
    con,
    paste(
      "SELECT CURRENT_ORGANIZATION_NAME() AS organization,",
      "CURRENT_ACCOUNT_NAME() AS account, CURRENT_USER() AS user,",
      "CURRENT_ROLE() AS role"
    )
  )
  print(identity)

  source <- data_source(con, tables = semantic_view)
  agent <- commons(
    ellmer::chat_anthropic(),
    data_sources = list(snowflake = source)
  )

  commons_prewarm(agent)
  shinychat::chat_server("chat", client = agent)
}

shinyApp(ui, server)
