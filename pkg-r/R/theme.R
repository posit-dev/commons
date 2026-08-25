#' bslib theme carrying the commons chat assets
#'
#' `commons_theme()` starts from [shinychat::page_chat_theme()] and attaches
#' the commons chat stylesheet and JavaScript as an HTML dependency bundled
#' into the theme itself. Because the result is an ordinary
#' [bslib::bs_theme()], it works anywhere a bslib theme does: as the `theme`
#' argument of [shinychat::page_chat()], [bslib::page_fillable()], or any
#' other bslib page function.
#'
#' Pair the theme with [shinychat::chat_ui()] (embedded in a bslib page) or
#' [shinychat::page_chat()] on the UI side, and [commons_server()] on the
#' server side.
#'
#' @param ... Named Sass variables forwarded to [shinychat::page_chat_theme()].
#' @param preset A bslib or Bootswatch preset name.
#'
#' @return A [bslib::bs_theme()] object.
#'
#' @examples
#' \dontrun{
#' library(shiny)
#' library(shinychat)
#'
#' ui <- page_chat("Assistant", id = "chat", theme = commons_theme())
#'
#' server <- function(input, output, session) {
#'   agent <- commons(
#'     ellmer::chat_anthropic(),
#'     data_sources = data_source(sales = sales)
#'   )
#'   commons_server("chat", agent)
#' }
#'
#' shinyApp(ui, server)
#' }
#'
#' @export
commons_theme <- function(..., preset = "shiny") {
  theme <- shinychat::page_chat_theme(
    # User-message geometry, formerly a CSS override in commons-chat.css;
    # shinychat exposes these as public theme variables.
    "shiny-chat-user-message-border-radius" = "1.25rem",
    "shiny-chat-user-message-padding" = "0.65rem 1.1rem",
    ...,
    preset = preset
  )
  bslib::bs_bundle(
    theme,
    sass::sass_layer(html_deps = list(commons_chat_dependency()))
  )
}
