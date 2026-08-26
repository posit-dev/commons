#' @rdname commons_server
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
