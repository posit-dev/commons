library(commons)

corpus <- list(list(
  label = "documentation",
  kind = "prose",
  text = "Canopy cover is always acre-weighted for reporting."
))
citation <- paste0(
  "<commons-citation>\n\nSupports the weighting rule.\n\n",
  "> Canopy cover is always acre-weighted for reporting.\n\n",
  "</commons-citation>"
)
code <- commons:::project_citation_text(
  paste0("```r\n1 + 1\n```\n\n", citation),
  corpus
)$text
table <- commons:::project_citation_text(
  paste0("| value |\n| ---: |\n| 2 |\n\n", citation),
  corpus
)$text

ui <- bslib::page_fillable(
  commons_ui(
    "chat",
    messages = list(
      list(role = "assistant", content = code),
      list(role = "assistant", content = table)
    )
  )
)

server <- function(input, output, session) {}
shiny::shinyApp(ui, server)
