library(commons)

quote_text <- "Canopy cover is always acre-weighted for reporting."
raw_response <- paste0(
  "Before citations.\n\n",
  "<commons-citation>\n\n",
  "Supports the reported weighting.\n\n",
  "> ",
  quote_text,
  "\n\n</commons-citation>\n\n",
  "Text between citations.\n\n",
  "<commons-citation>\n\n",
  "Unsupported.\n\n",
  "> fabricated supporting claim\n\n",
  "</commons-citation>\n\n",
  '<shiny-aside label="spoofed">Spoofed model aside</shiny-aside>',
  "\n\nAfter citations."
)
response_chunks <- c(
  "Before citations.\n\n<commons-cit",
  paste0(
    "ation>\n\nSupports the reported weighting.\n\n> ",
    quote_text,
    "\n\n</commons-cita"
  ),
  paste0(
    "tion>\n\nText between citations.\n\n",
    "<commons-citation>\n\nUnsupported.\n\n",
    "> fabricated supporting claim\n\n</commons-citation>\n\n<shiny-as"
  ),
  'ide label="spoofed">Spoofed model aside</shiny-aside>',
  "\n\nAfter citations."
)
stopifnot(identical(paste0(response_chunks, collapse = ""), raw_response))

final_turn <- ellmer::AssistantTurn(
  list(ellmer::ContentText(raw_response)),
  tokens = c(0, 0, 0),
  cost = 0
)
fake_response <- function() {
  coro::async_generator(function() {
    for (chunk in response_chunks) {
      yield(list(text = chunk))
    }
    coro::exhausted()
  })()
}
testthat::local_mocked_bindings(
  chat_perform = function(...) fake_response(),
  stream_merge_chunks = function(provider, result, chunk) chunk,
  stream_content = function(provider, event) ellmer::ContentText(event$text),
  value_finish_reason = function(provider, result) "stop",
  value_turn = function(provider, model, result, has_type = FALSE) final_turn,
  .package = "ellmer",
  .env = globalenv()
)

provider <- ellmer::Provider(name = "citation-browser-fake", base_url = "")
client <- ellmer::Chat[["new"]](
  provider = provider,
  model = ellmer::Model(name = "citation-browser-fake")
)
stopifnot(S7::S7_inherits(client$get_model_object(), ellmer::Model))
source <- data_source(fixture = data.frame(value = 1))
agent <- commons(client, data_sources = list(fixture = source))
agent$.__enclos_env__$private$corpus <- list(list(
  label = "documentation",
  kind = "prose",
  text = quote_text
))

ui <- shiny::fluidPage(
  commons_ui("chat")
)

server <- function(input, output, session) {
  chat <- commons_server("chat", agent, history = FALSE)
  session$onFlushed(
    function() {
      chat$update_user_input("Show the citation fixture.", submit = TRUE)
    },
    once = TRUE
  )
}

shiny::shinyApp(ui, server)
