derive_tag <- function(calls) {
  if ("run_sql" %in% calls) {
    return("B")
  }
  if ("call_measure" %in% calls) {
    return("A")
  }
  NA_character_
}

write_trajectory <- function(log_dir, record) {
  if (!dir.exists(log_dir)) {
    dir.create(log_dir, recursive = TRUE)
  }
  stamp <- format(Sys.time(), "%Y%m%dT%H%M%OS3")
  path <- file.path(log_dir, sprintf("turn-%s.json", stamp))
  jsonlite::write_json(record, path, auto_unbox = TRUE, pretty = TRUE)
  path
}
