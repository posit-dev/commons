tool_load_skill <- function(tool_names = character()) {
  skills <- builtin_skills(tool_names)
  ellmer::tool(
    function(name) {
      skill <- skills[[name]]
      if (is.null(skill)) {
        cli::cli_abort("There is no skill named {.val {name}}.")
      }
      tool_result(
        skill$body,
        title = paste("Read up on", skill$topic),
        icon = maybe_icon("book")
      )
    },
    load_skill_description(skills),
    name = "load_skill",
    arguments = list(
      name = ellmer::type_enum(names(skills), "The skill to load.")
    ),
    annotations = ellmer::tool_annotations(
      title = "Reading up",
      icon = maybe_icon("book"),
      read_only_hint = TRUE
    )
  )
}

load_skill_description <- function(skills) {
  listing <- vapply(
    skills,
    function(skill) paste0("- ", skill$name, ": ", skill$description),
    character(1)
  )
  paste(
    c(
      paste(
        "Load a skill's instructions. When a request matches one of these",
        "skills, load it before you respond:"
      ),
      "",
      listing
    ),
    collapse = "\n"
  )
}

# Each skill is a directory holding a SKILL.md, in the Agent Skills format:
# YAML frontmatter with a name and description, then the instructions. A
# skill that `requires` a tool is offered only when that tool is registered.
builtin_skills <- function(tool_names = character()) {
  dir <- system.file("prompts", "skills", package = "commons")
  paths <- file.path(sort(list.dirs(dir, recursive = FALSE)), "SKILL.md")
  skills <- lapply(paths, read_skill)
  skills <- Filter(
    function(skill) is.null(skill$requires) || skill$requires %in% tool_names,
    skills
  )
  names(skills) <- vapply(skills, function(skill) skill$name, character(1))
  skills
}

read_skill <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  end <- which(lines == "---")[2]
  meta <- yaml::yaml.load(paste(lines[seq.int(2L, end - 1L)], collapse = "\n"))
  list(
    name = meta$name,
    description = meta$description,
    topic = meta$metadata$topic,
    requires = meta$metadata$requires,
    body = trimws(paste(lines[-seq_len(end)], collapse = "\n"))
  )
}
