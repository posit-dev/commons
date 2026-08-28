#' @rdname commons_server
#' @export
commons_theme <- function(..., preset = "shiny") {
  theme <- shinychat::page_chat_theme(
    "shiny-chat-page-title-font-weight" = 300,
    "shiny-chat-user-message-border-radius" = "1.25rem",
    "shiny-chat-user-message-padding" = "0.5rem 1.5rem",
    ...,
    preset = preset
  )
  bslib::bs_bundle(
    theme,
    sass::sass_layer(html_deps = list(commons_chat_dependency()))
  )
}
