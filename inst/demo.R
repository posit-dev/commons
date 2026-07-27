# A self-contained commons agent over made-up forest canopy data.
# shiny::runApp("inst/demo.R")

library(shiny)
library(bslib)
devtools::load_all(".")

stands <- data.frame(
  stand_id = 1:8,
  name = c(
    "Nehalem Bench", "Saddle Mountain", "Mohawk Divide", "Fall Creek",
    "Winberry Ridge", "Sprague Rim", "Chiloquin Flat", "Antelope Draw"
  ),
  county = c(
    "Clatsop", "Clatsop", "Lane", "Lane",
    "Lane", "Klamath", "Klamath", "Klamath"
  ),
  forest_type = c(
    "Douglas-fir", "Sitka spruce", "Douglas-fir", "mixed conifer",
    "Douglas-fir", "ponderosa pine", "ponderosa pine", "lodgepole pine"
  ),
  status = c(
    "established", "established", "established", "established",
    "regeneration", "established", "established", "regeneration"
  ),
  acres = c(1240, 860, 3150, 720, 410, 2480, 1590, 640)
)

surveys <- data.frame(
  stand_id = rep(1:8, each = 2),
  survey_year = rep(c(2021, 2026), times = 8),
  canopy_pct = c(
    78, 81,
    84, 86,
    71, 74,
    62, 67,
    18, 34,
    45, 47,
    52, 49,
    12, 26
  )
)

notes <- tempfile(fileext = ".md")
writeLines(
  c(
    "Canopy cover is always acre-weighted. A plain average across stands treats a 400-acre unit the same as a 4,000-acre one.",
    "",
    "Baseline canopy statistics cover established stands only; regeneration units are tracked separately until they close canopy.",
    "",
    "The surveys table has one row per stand per survey year, so a query that doesn't pin a year mixes survey cycles."
  ),
  notes
)

sem <- semantic_layer(
  measure(
    "canopy_by_county",
    "Acre-weighted canopy cover for each county, from the most recent survey.",
    function(warehouse) {
      DBI::dbGetQuery(
        warehouse,
        "SELECT county,
                SUM(canopy_pct * acres) / SUM(acres) AS canopy_pct,
                SUM(acres) AS acres
         FROM stands JOIN surveys USING (stand_id)
         WHERE status = 'established'
           AND survey_year = (SELECT MAX(survey_year) FROM surveys)
         GROUP BY county ORDER BY canopy_pct DESC"
      )
    }
  ),
  measure(
    "low_canopy_stands",
    "Established stands with the least canopy cover today, thinnest first.",
    function(warehouse) {
      DBI::dbGetQuery(
        warehouse,
        "SELECT name, county, forest_type, canopy_pct, acres
         FROM stands JOIN surveys USING (stand_id)
         WHERE status = 'established'
           AND survey_year = (SELECT MAX(survey_year) FROM surveys)
         ORDER BY canopy_pct"
      )
    }
  )
)

welcome_message <- paste(
  "Chat with this agent to learn about canopy cover in Oregon's forests.",
  "\n\nHere are some example questions:\n\n",
  "- <span class='suggestion'>Which county has the most canopy cover?</span>\n",
  "- <span class='suggestion'>Which stands have the least canopy cover?</span>\n",
  "- <span class='suggestion'>How much canopy has Winberry Ridge gained since 2021?</span>\n"
)

ui <- page_fillable(
  commons_ui("chat", greeting = welcome_message)
)

server <- function(input, output, session) {
  agent <- commons(
    ellmer::chat_anthropic(),
    data_sources = list(
      warehouse = data_source(stands = stands, surveys = surveys)
    ),
    semantic_layer = sem,
    context_layer = context_layer(files = notes)
  )

  commons_server("chat", agent)
}

shinyApp(ui, server)
