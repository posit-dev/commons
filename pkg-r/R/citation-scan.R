# Require explicit blockquote lines so wrapped evidence fails closed instead
# of verifying only its first line.
parse_commons_citation <- function(body) {
  lines <- strsplit(body, "\n", fixed = TRUE)[[1]]
  quoted <- grepl("^> ?", lines)
  runs <- rle(quoted)
  if (sum(runs$values) != 1) {
    return(NULL)
  }
  quote <- paste(sub("^> ?", "", lines[quoted]), collapse = "\n")
  explanation <- trimws(paste(lines[!quoted], collapse = "\n"))
  list(explanation = explanation, quote = quote)
}

# Hold partial reserved tags between chunks so projection does not depend on
# stream chunk boundaries.
CITATION_OPEN <- "<commons-citation>"
CITATION_CLOSE <- "</commons-citation>"
ASIDE_OPEN <- "<shiny-aside"
ASIDE_CLOSE <- "</shiny-aside>"
ELEMENT_BODY_CAP <- 16384L
# An open tag with attributes and a bare one are separate literals, so neither
# matches a longer element name such as the chip's.
ARTIFACT_OPEN <- "<artifact "
ARTIFACT_OPEN_BARE <- "<artifact>"
ARTIFACT_CLOSE <- "</artifact>"
ARTIFACT_HEADER_CAP <- 1024L
ARTIFACT_BODY_CAP <- 200000L

# `on_artifact` receives artifact events as they stream; whatever it returns
# for a `close` event takes the element's place in the projected text.
citation_scanner <- function(corpus = list(), on_artifact = NULL) {
  resolve <- function(parsed) {
    if (is.null(parsed)) {
      return(list(
        html = "",
        decision = list(quote = NA_character_, status = "malformed")
      ))
    }
    render_citation_aside(parsed$quote, parsed$explanation, corpus)
  }
  buf <- ""
  mode <- "text"
  at_line_start <- TRUE
  decisions <- list()
  out <- character(0)
  discard_close <- NULL
  artifact <- NULL

  emit <- function(text) {
    if (nzchar(text)) out[[length(out) + 1]] <<- text
  }

  # Tag anchoring follows the model's input, not the projected output.
  note_line_start <- function(original_text) {
    if (nzchar(original_text)) {
      at_line_start <<- endsWith(original_text, "\n")
    }
  }

  record <- function(decision) {
    decisions[[length(decisions) + 1]] <<- decision
  }

  begin_discard <- function(close_literal) {
    mode <<- "discard"
    discard_close <<- close_literal
  }

  notify <- function(event) {
    if (is.null(on_artifact)) {
      return("")
    }
    on_artifact(event) %||% ""
  }

  fail_artifact <- function(reason) {
    notify(list(type = "error", id = artifact$id, reason = reason))
    artifact <<- NULL
  }

  step <- function() {
    if (mode == "text") {
      event <- find_text_event(buf, at_line_start)
      if (!is.null(event)) {
        prefix <- substr(buf, 1, event$pos - 1)
        literal <- substr(buf, event$pos, event$pos + event$len - 1L)
        emit(prefix)
        note_line_start(prefix)
        buf <<- substr(buf, event$pos + event$len, nchar(buf))
        if (identical(event$mode, "citation")) {
          mode <<- "citation"
        } else if (identical(event$mode, "aside")) {
          begin_discard(ASIDE_CLOSE)
        } else if (identical(event$mode, "artifact")) {
          mode <<- "artifact_header"
          # The bare literal has already consumed the header's closing `>`.
          if (identical(tolower(literal), ARTIFACT_OPEN_BARE)) {
            buf <<- paste0(">", buf)
          }
        } else {
          note_line_start(literal)
        }
        return(TRUE)
      }
      holdback <- holdback_length(buf, at_line_start)
      flush_len <- nchar(buf) - holdback
      if (flush_len > 0) {
        flushed <- substr(buf, 1, flush_len)
        emit(flushed)
        note_line_start(flushed)
        buf <<- substr(buf, flush_len + 1, nchar(buf))
      }
      return(FALSE)
    }

    if (mode == "citation") {
      event <- find_reserved_event(buf)
      if (
        !is.null(event) &&
          identical(event$action, "close") &&
          identical(event$kind, "citation") &&
          (event$pos - 1L) <= ELEMENT_BODY_CAP
      ) {
        body <- substr(buf, 1, event$pos - 1L)
        buf <<- substr(buf, event$pos + event$len, nchar(buf))
        close_citation(body)
        mode <<- "text"
        at_line_start <<- FALSE
        return(TRUE)
      }
      if (!is.null(event)) {
        begin_discard(CITATION_CLOSE)
        return(TRUE)
      }
      if (confirmed_body_len(buf, CITATION_CLOSE) > ELEMENT_BODY_CAP) {
        begin_discard(CITATION_CLOSE)
        return(TRUE)
      }
      return(FALSE)
    }

    if (mode == "artifact_header") {
      return(step_artifact_header())
    }

    if (mode == "artifact") {
      return(step_artifact())
    }

    pos <- find_ci(buf, discard_close)
    if (!is.na(pos)) {
      consumed <- substr(buf, 1, pos + nchar(discard_close) - 1L)
      note_line_start(consumed)
      buf <<- substr(buf, pos + nchar(discard_close), nchar(buf))
      mode <<- "text"
      discard_close <<- NULL
      return(TRUE)
    }

    holdback <- longest_valid_suffix(
      buf,
      discard_close,
      function(start) TRUE
    )
    drop_len <- nchar(buf) - holdback
    if (drop_len > 0) {
      dropped <- substr(buf, 1, drop_len)
      note_line_start(dropped)
      buf <<- substr(buf, drop_len + 1L, nchar(buf))
    }
    FALSE
  }

  step_artifact_header <- function() {
    end <- regexpr(">", buf, fixed = TRUE)
    newline <- regexpr("\n", buf, fixed = TRUE)
    if (end == -1L) {
      if (newline != -1L || nchar(buf) > ARTIFACT_HEADER_CAP) {
        fail_artifact("malformed")
        begin_discard(ARTIFACT_CLOSE)
        return(TRUE)
      }
      return(FALSE)
    }
    header <- substr(buf, 1L, end - 1L)
    buf <<- substr(buf, end + 1L, nchar(buf))
    attrs <- parse_artifact_attributes(header)
    if (
      (newline != -1L && newline < end) ||
        nchar(header) > ARTIFACT_HEADER_CAP ||
        is.null(attrs)
    ) {
      fail_artifact("malformed")
      begin_discard(ARTIFACT_CLOSE)
      return(TRUE)
    }
    artifact <<- c(attrs, list(body = character(), length = 0L))
    notify(list(type = "open", id = attrs$id, title = attrs$title))
    mode <<- "artifact"
    TRUE
  }

  step_artifact <- function() {
    pos <- find_ci(buf, ARTIFACT_CLOSE)
    take <- if (is.na(pos)) {
      nchar(buf) - longest_valid_suffix(buf, ARTIFACT_CLOSE, function(start) TRUE)
    } else {
      pos - 1L
    }
    if (artifact$length + take > ARTIFACT_BODY_CAP) {
      fail_artifact("too_long")
      begin_discard(ARTIFACT_CLOSE)
      return(TRUE)
    }
    if (take > 0L) {
      text <- substr(buf, 1L, take)
      artifact$body <<- c(artifact$body, text)
      artifact$length <<- artifact$length + take
      notify(list(type = "delta", id = artifact$id, text = text))
    }
    if (is.na(pos)) {
      buf <<- substr(buf, take + 1L, nchar(buf))
      return(FALSE)
    }
    buf <<- substr(buf, pos + nchar(ARTIFACT_CLOSE), nchar(buf))
    emit(notify(list(
      type = "close",
      id = artifact$id,
      title = artifact$title,
      body = paste(artifact$body, collapse = "")
    )))
    artifact <<- NULL
    mode <<- "text"
    at_line_start <<- FALSE
    TRUE
  }

  close_citation <- function(body) {
    result <- resolve(parse_commons_citation(body))
    emit(result$html)
    record(result$decision)
    invisible()
  }

  list(
    feed = function(chunk) {
      buf <<- paste0(buf, chunk)
      out <<- character(0)
      while (step()) {}
      paste(out, collapse = "")
    },
    finish = function() {
      if (mode == "text") {
        flushed <- buf
        buf <<- ""
        return(flushed)
      }
      # Never expose incomplete model-authored markup.
      if (mode %in% c("artifact_header", "artifact")) {
        fail_artifact("unclosed")
      }
      buf <<- ""
      mode <<- "text"
      discard_close <<- NULL
      ""
    },
    decisions = function() decisions
  )
}

project_citation_text <- function(text, corpus) {
  s <- citation_scanner(corpus)
  out <- paste0(s$feed(text), s$finish())
  list(text = out, decisions = s$decisions())
}

# Opening tags that only count at the start of a line, and literals that count
# anywhere.
anchored_literals <- function() {
  list(
    list(literal = CITATION_OPEN, mode = "citation"),
    list(literal = ARTIFACT_OPEN, mode = "artifact"),
    list(literal = ARTIFACT_OPEN_BARE, mode = "artifact")
  )
}

unanchored_literals <- function() {
  list(
    list(literal = ASIDE_OPEN, mode = "aside"),
    list(literal = CITATION_CLOSE, mode = "drop"),
    list(literal = ASIDE_CLOSE, mode = "drop"),
    list(literal = ARTIFACT_CLOSE, mode = "drop")
  )
}

find_text_event <- function(buf, at_line_start) {
  candidates <- list()
  for (entry in anchored_literals()) {
    pattern <- paste0(
      if (at_line_start) "(?:^|(?<=\n))" else "(?<=\n)",
      "\\Q",
      entry$literal,
      "\\E"
    )
    pos <- regexpr(pattern, buf, perl = TRUE, ignore.case = TRUE)
    if (pos != -1) {
      candidates[[length(candidates) + 1]] <- list(
        pos = as.integer(pos),
        len = nchar(entry$literal),
        mode = entry$mode
      )
    }
  }
  for (entry in unanchored_literals()) {
    pos <- find_ci(buf, entry$literal)
    if (!is.na(pos)) {
      candidates[[length(candidates) + 1]] <- list(
        pos = pos,
        len = nchar(entry$literal),
        mode = entry$mode
      )
    }
  }
  if (length(candidates) == 0) {
    return(NULL)
  }
  candidates[[which.min(vapply(candidates, function(c) c$pos, integer(1)))]]
}

find_ci <- function(buf, literal) {
  pos <- regexpr(tolower(literal), tolower(buf), fixed = TRUE)
  if (pos == -1) NA_integer_ else as.integer(pos)
}

find_reserved_event <- function(buf) {
  events <- list(
    list(literal = CITATION_OPEN, kind = "citation", action = "open"),
    list(literal = CITATION_CLOSE, kind = "citation", action = "close"),
    list(literal = ASIDE_OPEN, kind = "aside", action = "open"),
    list(literal = ASIDE_CLOSE, kind = "aside", action = "close")
  )
  for (i in seq_along(events)) {
    events[[i]]$pos <- find_ci(buf, events[[i]]$literal)
    events[[i]]$len <- nchar(events[[i]]$literal)
  }
  events <- Filter(function(event) !is.na(event$pos), events)
  if (length(events) == 0) {
    return(NULL)
  }
  events[[which.min(vapply(events, function(event) event$pos, integer(1)))]]
}

# Exclude a partial closing tag from the body cap so chunk boundaries cannot
# change whether a citation is accepted.
confirmed_body_len <- function(buf, close_literal) {
  holdback <- longest_valid_suffix(buf, close_literal, function(start) TRUE)
  nchar(buf) - holdback
}

holdback_length <- function(buf, at_line_start) {
  line_anchor <- function(start) {
    if (start == 1) {
      at_line_start
    } else {
      identical(substr(buf, start - 1, start - 1), "\n")
    }
  }
  max(
    vapply(
      anchored_literals(),
      function(entry) longest_valid_suffix(buf, entry$literal, line_anchor),
      integer(1)
    ),
    vapply(
      unanchored_literals(),
      function(entry) {
        longest_valid_suffix(buf, entry$literal, function(start) TRUE)
      },
      integer(1)
    )
  )
}

longest_valid_suffix <- function(buf, literal, anchor_ok) {
  n <- nchar(buf)
  max_len <- min(n, nchar(literal) - 1L)
  if (max_len < 1L) {
    return(0L)
  }
  for (len in max_len:1) {
    start <- n - len + 1L
    if (!anchor_ok(start)) {
      next
    }
    if (is_ci_prefix(substr(buf, start, n), literal, len)) {
      return(len)
    }
  }
  0L
}

is_ci_prefix <- function(suffix, literal, len) {
  identical(tolower(suffix), tolower(substr(literal, 1, len)))
}

# The header is everything between `<artifact` and `>`: quoted
# attributes only. An id is required and becomes a directory name, so it is a
# lowercase slug.
parse_artifact_attributes <- function(header) {
  pattern <- "([A-Za-z][A-Za-z0-9_-]*)[ \t]*=[ \t]*(\"[^\"]*\"|'[^']*')"
  found <- regmatches(header, gregexpr(pattern, header, perl = TRUE))[[1]]
  leftover <- gsub(pattern, "", header, perl = TRUE)
  if (grepl("[^ \t]", leftover)) {
    return(NULL)
  }
  names <- tolower(sub(pattern, "\\1", found, perl = TRUE))
  values <- sub(pattern, "\\2", found, perl = TRUE)
  values <- substr(values, 2L, nchar(values) - 1L)
  attrs <- as.list(rlang::set_names(values, names))
  id <- attrs$id
  if (!is_artifact_id(id)) {
    return(NULL)
  }
  title <- trimws(attrs$title %||% "")
  list(id = id, title = if (nzchar(title)) title else id)
}

is_artifact_id <- function(id) {
  rlang::is_string(id) &&
    nchar(id) <= 64L &&
    grepl("^[a-z0-9]+(-[a-z0-9]+)*$", id)
}
