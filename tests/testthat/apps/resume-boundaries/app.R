library(commons)

messages <- list(
  list(role = "user", content = "Question one"),
  list(role = "assistant", content = "Answer one"),
  list(role = "user", content = "Question two"),
  list(role = "assistant", content = "Answer two"),
  list(role = "user", content = "Question three"),
  list(role = "assistant", content = "Answer three")
)

append_messages <- function(prefix = "") {
  for (message in messages) {
    shinychat::chat_append(
      "chat",
      paste0(prefix, message$content),
      role = message$role
    )
  }
}

ui <- bslib::page_fillable(
  shiny::actionButton("replay", "Replay"),
  shiny::actionButton("clear", "Clear"),
  shiny::actionButton("append", "Append"),
  commons_ui("chat", messages = messages)
)

server <- function(input, output, session) {
  session$onFlushed(
    function() {
      session$sendCustomMessage(
        "commonsResumeConversation",
        list(
          id = session$ns("chat"),
          input_id = session$ns("chat_resume_boundaries"),
          boundaries = c(2L, 4L)
        )
      )
    },
    once = TRUE
  )

  shiny::observeEvent(input$replay, {
    shinychat::chat_clear("chat")
    append_messages("Replayed ")
  })

  shiny::observeEvent(input$clear, {
    shinychat::chat_clear("chat")
  })

  shiny::observeEvent(input$append, {
    shinychat::chat_append("chat", "A new conversation")
  })
}

shiny::shinyApp(ui, server)
