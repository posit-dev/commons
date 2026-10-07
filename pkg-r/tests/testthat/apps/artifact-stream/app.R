library(commons)

document <- paste0(
  "---\ntitle: Orders by region\ncommons:\n  inputs:\n    orders:\n",
  "      measure: orders\n---\n\n",
  "## Summary\n\n",
  "There are `r nrow(orders)` orders across **three** regions.\n\n",
  "```{r}\ntable(orders$region)\n```\n\n",
  "- EMEA leads.\n- APAC trails.\n"
)
response_chunks <- c(
  "I wrote the report.\n\n<commons-arti",
  paste0("fact id=\"orders\" title=\"Orders by region\">\n", substr(document, 1, 80)),
  substr(document, 81, 160),
  substr(document, 161, nchar(document)),
  "</commons-artifact>\n\nIt covers every region."
)
raw_response <- paste0(response_chunks, collapse = "")

final_turn <- ellmer::AssistantTurn(
  list(ellmer::ContentText(raw_response)),
  tokens = c(0, 0, 0),
  cost = 0
)
fake_response <- function() {
  coro::async_generator(function() {
    for (chunk in response_chunks) {
      Sys.sleep(0.3)
      yield(list(text = chunk))
    }
    coro::exhausted()
  })()
}
testthat::local_mocked_bindings(
  chat_perform = function(...) fake_response(),
  stream_merge_chunks = function(provider, result, chunk) chunk,
  stream_content_with_turns = function(
    provider,
    event,
    completion = NULL,
    turns = list()
  ) {
    list(ellmer::ContentText(event$text))
  },
  value_finish_reason = function(provider, result) "stop",
  value_turn_with_turns = function(
    provider,
    model,
    result,
    has_type = FALSE,
    turns = list()
  ) {
    final_turn
  },
  .package = "ellmer",
  .env = globalenv()
)

provider <- ellmer::Provider(name = "artifact-browser-fake", base_url = "")
client <- ellmer::Chat[["new"]](
  provider = provider,
  model = ellmer::Model(name = "artifact-browser-fake")
)
sales <- data.frame(
  region = c("EMEA", "EMEA", "Americas", "APAC"),
  revenue = c(500, 1200, 900, 300)
)
agent <- commons(
  client,
  data_sources = list(sales = data_source(sales = sales)),
  semantic_layer = semantic_layer(
    measure("orders", "All orders.", function() sales, arguments = list())
  )
)

ui <- shinychat::page_chat("Artifacts", id = "chat", theme = commons_theme())

server <- function(input, output, session) {
  chat <- commons_server("chat", agent, history = FALSE)
  session$onFlushed(
    function() {
      chat$update_user_input("Write the orders report.", submit = TRUE)
    },
    once = TRUE
  )
}

shiny::shinyApp(ui, server)
