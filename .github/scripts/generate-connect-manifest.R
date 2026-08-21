project <- getwd()
ref <- Sys.getenv("COMMONS_REF")
project_library <- renv::paths$library(project = project)

if (!nzchar(ref)) {
  stop("COMMONS_REF must contain the Git commit being deployed.", call. = FALSE)
}

renv::install(
  sprintf("github::posit-dev/commons@%s", ref),
  library = project_library,
  project = project,
  rebuild = TRUE,
  prompt = FALSE
)
.libPaths(c(project_library, .libPaths()))

app_files <- c(
  "app.R",
  "www/commons-chat/commons-chat.css",
  "www/commons-chat/commons-chat.js"
)

if (!all(file.exists(file.path("inst", app_files)))) {
  stop("The Connect app files are missing from inst/.", call. = FALSE)
}

rsconnect::writeManifest(
  appDir = "inst",
  appFiles = app_files,
  appMode = "shiny",
  dependencyResolution = "strict",
  quiet = FALSE
)
