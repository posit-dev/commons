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

# shinychat shows a user turn with nothing left to display as an empty
# message, so the hidden follow-up turns come out first. The replies on either
# side of one then merge into a single message, as they streamed.
S7::method(
  contents_shinychat,
  S7::new_S3_class(c("Commons", "Chat", "R6"))
) <- function(content) {
  chat <- new_trajectory_chat()
  chat$set_tools(content$get_tools())
  chat$set_turns(Filter(Negate(is_internal_turn), content$get_turns()))
  shinychat::contents_shinychat(chat)
}

new_trajectory_chat <- function() {
  ellmer::chat_openai(
    credentials = \() "unused",
    model = "transcript-display"
  )
}

# Assistant text as the model wrote it, with the projection the chat showed:
# citations as asides and documents as links. shinychat rebuilds a restored
# conversation from its turns, so without this it would show the raw markup.
ContentProjectedText <- S7::new_class(
  "ContentProjectedText",
  parent = ellmer::ContentText,
  properties = list(display = S7::class_character)
)

S7::method(contents_shinychat, ContentProjectedText) <- function(content) {
  content@display
}

project_turns_display <- function(turns, from, corpus, artifacts = NULL) {
  on_artifact <- function(event) {
    if (identical(event$type, "close")) {
      artifact_turn_link(artifacts, event)
    } else {
      ""
    }
  }
  for (i in seq_along(turns)[seq_along(turns) >= from]) {
    if (!S7::S7_inherits(turns[[i]], ellmer::AssistantTurn)) {
      next
    }
    turns[[i]]@contents <- lapply(turns[[i]]@contents, function(content) {
      if (!identical(class(content)[[1]], "ellmer::ContentText")) {
        return(content)
      }
      scanner <- citation_scanner(corpus, on_artifact = on_artifact)
      display <- paste0(scanner$feed(content@text), scanner$finish())
      if (identical(display, content@text)) {
        return(content)
      }
      ContentProjectedText(text = content@text, display = display)
    })
  }
  turns
}

brevity_turn_reminder <- "<system-instruction>Be concise as a default.</system-instruction>"

restored_conversation_turn_reminder <- paste0(
  "<system-instruction>The R state associated with this restored ",
  "conversation is unavailable. Do not assume that objects, loaded packages, ",
  "or result handles from earlier run_r calls still exist. Re-run needed ",
  "tools, recreate objects, and reload packages before continuing.",
  "</system-instruction>"
)

append_turn_reminder <- function(inputs, model) {
  if (!needs_brevity_prompting(model)) {
    return(inputs)
  }
  c(inputs, list(ContentTurnReminder(text = brevity_turn_reminder)))
}

append_restored_conversation_reminder <- function(inputs) {
  c(
    inputs,
    list(ContentTurnReminder(text = restored_conversation_turn_reminder))
  )
}
