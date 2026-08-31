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

# Content-based prefix check: shinychat replays stored turns through
# ellmer::contents_replay(), so object identity is not meaningful here.
turns_are_prefix <- function(value, current) {
  if (length(value) > length(current)) {
    return(FALSE)
  }
  identical(
    vapply(value, turn_text_signature, character(1)),
    vapply(current[seq_along(value)], turn_text_signature, character(1))
  )
}

# Distinct from trajectory-read.R's turn_signature(), which produces a
# structured signature for exchange matching.
turn_text_signature <- function(turn) {
  texts <- vapply(
    turn@contents,
    function(content) {
      if (S7::S7_inherits(content, ellmer::ContentText)) content@text else ""
    },
    character(1)
  )
  paste(c(turn@role, texts), collapse = "\x1f")
}
