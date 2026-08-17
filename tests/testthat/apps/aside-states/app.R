library(commons)

citation <- commons:::render_citation_aside(
  "Canopy cover is always acre-weighted for reporting.",
  "Supports the reported weighting.",
  list(list(
    label = "documentation",
    kind = "prose",
    text = "Canopy cover is always acre-weighted for reporting."
  ))
)$html

ui <- shiny::fluidPage(
  commons_ui(
    "chat",
    messages = list(
      list(
        role = "assistant",
        content = paste("Governed result.", commons:::provenance_aside("A"))
      ),
      list(
        role = "assistant",
        content = paste0("Supported claim.\n", citation)
      ),
      list(
        role = "assistant",
        content = paste("Fallback result.", commons:::provenance_aside("C"))
      )
    )
  )
)

server <- function(input, output, session) {}

shiny::shinyApp(ui, server)
