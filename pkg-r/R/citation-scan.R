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

citation_scanner <- function(corpus = list()) {
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

find_text_event <- function(buf, at_line_start) {
  citation_pattern <- if (at_line_start) {
    "(?:^|(?<=\n))<commons-citation>"
  } else {
    "(?<=\n)<commons-citation>"
  }
  citation_pos <- regexpr(
    citation_pattern,
    buf,
    perl = TRUE,
    ignore.case = TRUE
  )
  aside_pos <- regexpr(tolower(ASIDE_OPEN), tolower(buf), fixed = TRUE)

  candidates <- list()
  if (citation_pos != -1) {
    candidates[[length(candidates) + 1]] <- list(
      pos = as.integer(citation_pos),
      len = nchar(CITATION_OPEN),
      mode = "citation"
    )
  }
  if (aside_pos != -1) {
    candidates[[length(candidates) + 1]] <- list(
      pos = as.integer(aside_pos),
      len = nchar(ASIDE_OPEN),
      mode = "aside"
    )
  }
  citation_close_pos <- find_ci(buf, CITATION_CLOSE)
  if (!is.na(citation_close_pos)) {
    candidates[[length(candidates) + 1]] <- list(
      pos = citation_close_pos,
      len = nchar(CITATION_CLOSE),
      mode = "drop"
    )
  }
  aside_close_pos <- find_ci(buf, ASIDE_CLOSE)
  if (!is.na(aside_close_pos)) {
    candidates[[length(candidates) + 1]] <- list(
      pos = aside_close_pos,
      len = nchar(ASIDE_CLOSE),
      mode = "drop"
    )
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
  citation_anchor <- function(start) {
    if (start == 1) {
      at_line_start
    } else {
      identical(substr(buf, start - 1, start - 1), "\n")
    }
  }
  max(
    longest_valid_suffix(buf, CITATION_OPEN, citation_anchor),
    longest_valid_suffix(buf, ASIDE_OPEN, function(start) TRUE),
    longest_valid_suffix(buf, CITATION_CLOSE, function(start) TRUE),
    longest_valid_suffix(buf, ASIDE_CLOSE, function(start) TRUE)
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
