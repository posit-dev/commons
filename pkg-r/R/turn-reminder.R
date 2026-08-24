ContentTurnReminder <- S7::new_class(
  "ContentTurnReminder",
  parent = ellmer::ContentText
)

contents_shinychat <- S7::new_external_generic(
  package = "shinychat",
  name = "contents_shinychat",
  dispatch_args = "content"
)

S7::method(contents_shinychat, ContentTurnReminder) <- function(content) {
  NULL
}

claude_5_turn_reminder <- "<reminder>Be concise as a default.</reminder>"

append_turn_reminder <- function(inputs, model) {
  if (!is_claude_5_model(model)) {
    return(inputs)
  }
  c(inputs, list(ContentTurnReminder(text = claude_5_turn_reminder)))
}
