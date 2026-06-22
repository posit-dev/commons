derive_tag <- function(calls) {
  if ("run_sql" %in% calls) {
    return("B")
  }
  if ("call_measure" %in% calls) {
    return("A")
  }
  NA_character_
}
