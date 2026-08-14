# Run from the repository root with:
# shiny::runApp("dev/plot-app")

library(bslib)
library(ggplot2)
library(shiny)

devtools::load_all("../..")

values <- data.frame(
  group = c("A", "B", "C"),
  value = c(8, 13, 5)
)

measures <- semantic_layer(
  measure(
    "value_plot",
    "Plot the value for each group.",
    function() {
      ggplot(values, aes(group, value, fill = group)) +
        geom_col(show.legend = FALSE) +
        labs(x = NULL, y = "Value")
    },
    title = "Values by group"
  )
)

ui <- page_fillable(
  theme = bs_theme(version = 5),
  commons_ui(
    "chat",
    greeting = "Try: <span class='suggestion'>Show the values by group.</span>"
  )
)

server <- function(input, output, session) {
  agent <- commons(
    ellmer::chat_anthropic(),
    data_sources = data_source(values = values),
    semantic_layer = measures
  )

  commons_server("chat", agent)
}

shinyApp(ui, server)
