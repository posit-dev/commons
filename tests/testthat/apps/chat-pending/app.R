library(commons)

ui <- bslib::page_fillable(
  commons_ui(
    "chat",
    greeting = "<span class='suggestion submit'>Ask a question</span>",
    enable_cancel = TRUE
  )
)

server <- function(input, output, session) {
  shiny::observeEvent(input$chat_user_input, {
    Sys.sleep(3)
    shinychat::chat_append("chat", "The response is ready.")
  })
}

shiny::shinyApp(ui, server)
