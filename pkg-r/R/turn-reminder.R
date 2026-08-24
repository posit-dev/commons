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

restored_conversation_turn_reminder <- paste0(
  "<reminder>The R state associated with this restored conversation is ",
  "unavailable. Do not assume that objects, loaded packages, or result ",
  "handles from earlier run_r calls still exist. Re-run needed tools, ",
  "recreate objects, and reload packages before continuing.</reminder>"
)

append_turn_reminder <- function(inputs, model) {
  if (!is_claude_5_model(model)) {
    return(inputs)
  }
  c(inputs, list(ContentTurnReminder(text = claude_5_turn_reminder)))
}

append_restored_conversation_reminder <- function(inputs) {
  c(
    inputs,
    list(ContentTurnReminder(text = restored_conversation_turn_reminder))
  )
}
