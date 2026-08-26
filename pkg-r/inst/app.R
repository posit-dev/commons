library(bslib)
if (interactive()) {
  devtools::load_all("./pkg-r")
} else {
  library(commons)
}
library(shiny)
library(shinychat)

observations <- data.frame(
  site = c(
    "Cedar Fen", "Cedar Fen", "Cedar Fen", "Cedar Fen", "Cedar Fen", "Cedar Fen",
    "Oak Bluff", "Oak Bluff", "Oak Bluff", "Oak Bluff", "Oak Bluff",
    "Prairie Fork", "Prairie Fork", "Prairie Fork", "Prairie Fork", "Prairie Fork",
    "Willow Marsh", "Willow Marsh", "Willow Marsh", "Willow Marsh", "Willow Marsh"
  ),
  habitat = c(rep("wetland", 6), rep("woodland", 5), rep("grassland", 5), rep("wetland", 5)),
  species = c(
    "Blanding's turtle", "Sedge wren", "Blue-spotted salamander", "Marsh marigold", "Muskrat", "Rusty patched bumble bee",
    "Red-headed woodpecker", "White oak", "Eastern chipmunk", "Wild geranium", "Barred owl",
    "Henslow's sparrow", "Monarch", "Big bluestem", "Prairie vole", "Bobolink",
    "King rail", "River otter", "Blue flag iris", "Great blue heron", "Painted turtle"
  ),
  taxon = c(
    "reptile", "bird", "amphibian", "plant", "mammal", "insect",
    "bird", "plant", "mammal", "plant", "bird",
    "bird", "insect", "plant", "mammal", "bird",
    "bird", "mammal", "plant", "bird", "reptile"
  ),
  count = c(4, 11, 8, 36, 3, 6, 2, 18, 7, 29, 3, 5, 24, 44, 9, 13, 2, 4, 31, 7, 12),
  conservation_status = c(
    "threatened", "special concern", "special concern", "secure", "secure", "endangered",
    "special concern", "secure", "secure", "secure", "secure",
    "threatened", "special concern", "secure", "secure", "special concern",
    "endangered", "secure", "secure", "secure", "secure"
  ),
  survey_year = 2025
)

site_area <- data.frame(
  site = c("Cedar Fen", "Oak Bluff", "Prairie Fork", "Willow Marsh"),
  protected_hectares = c(82, 125, 210, 96),
  survey_effort_hours = c(32, 28, 40, 35)
)

semantics <- semantic_layer(
  measure(
    "biodiversity_by_site",
    "Species richness, total individuals, and survey effort for every site.",
    function(warehouse) {
      DBI::dbGetQuery(
        warehouse,
        "SELECT site,
                COUNT(DISTINCT species) AS species_richness,
                SUM(count) AS individuals_observed,
                MAX(survey_effort_hours) AS survey_effort_hours
         FROM observations
         JOIN site_area USING (site)
         GROUP BY site
         ORDER BY species_richness DESC, individuals_observed DESC"
      )
    }
  ),
  measure(
    "species_of_concern",
    "Species whose conservation status is endangered, threatened, or special concern.",
    function(warehouse) {
      DBI::dbGetQuery(
        warehouse,
        "SELECT site, species, taxon, conservation_status, count
         FROM observations
         WHERE conservation_status != 'secure'
         ORDER BY CASE conservation_status
           WHEN 'endangered' THEN 1
           WHEN 'threatened' THEN 2
           ELSE 3 END, site, species"
      )
    }
  )
)

greeting <- paste(
  "Explore a fictional 2025 biodiversity survey of four nature preserves.",
  "\n\nTry one of these questions:\n\n",
  "- <span class='suggestion'>Which site has the greatest biodiversity?</span>\n",
  "- <span class='suggestion'>Where were threatened or endangered species found?</span>\n",
  "- <span class='suggestion'>Compare wetlands with the other habitats.</span>"
)

ui <- page_fillable(
  title = "Biodiversity explorer",
  commons_ui("chat", greeting = greeting)
)

server <- function(input, output, session) {
  agent <- commons(
    ellmer::chat_anthropic(),
    data_sources = list(
      warehouse = data_source(
        observations = observations,
        site_area = site_area
      )
    ),
    semantic_layer = semantics
  )

  commons_server("chat", agent)
}

shinyApp(ui, server)
