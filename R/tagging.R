derive_tag <- function(tags) {
  if ("B" %in% tags) {
    return("B")
  }
  if ("A" %in% tags) {
    return("A")
  }
  NA_character_
}

commons_last_tag <- function(chat) {
  derive_tag_from_turns(chat$get_turns(include_system_prompt = FALSE))
}

derive_tag_from_turns <- function(turns) {
  tags <- character()
  for (turn in rev(turns)) {
    if (identical(turn@role, "user") && !turn_has_tool_result(turn)) {
      break
    }
    tags <- c(tags, turn_tags(turn))
  }
  derive_tag(tags)
}

turn_has_tool_result <- function(turn) {
  any(vapply(turn@contents, is_tool_result_content, logical(1)))
}

turn_tags <- function(turn) {
  unlist(
    lapply(turn@contents, function(content) {
      if (is_tool_result_content(content)) {
        content@extra$commons_tag
      }
    }),
    use.names = FALSE
  )
}

is_tool_result_content <- function(content) {
  S7::S7_inherits(content, ellmer::ContentToolResult)
}
