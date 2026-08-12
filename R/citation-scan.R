# Body grammar for <commons-citation>: exactly one contiguous run of
# blockquote lines holds the verbatim evidence; everything else is the
# model's (unverified) explanation. Deliberately not CommonMark: no lazy
# continuation, so a wrapped quote fails verification rather than
# truncating into a "verified" fragment.
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

# Chunk-invariant incremental scanner: translates a model's
# <commons-citation> elements into server-authored <shiny-aside> markup (or
# drops them, unverified) while copying everything else through unchanged,
# regardless of where the caller's chunk boundaries fall. The only state
# that has to survive across feed() calls is: the unflushed tail of raw
# input (`buf`), which of three modes we're in, and whether the character
# immediately before `buf` in the *original* stream was a newline
# (`at_line_start` -- start-of-stream counts, since <commons-citation> is
# recognized at line start).
#
# In "text" mode, `buf` can only ever be flushed up to the start of the
# longest suffix that is still a case-insensitive prefix of a reserved
# literal -- that suffix might complete into a real tag on the next feed()
# call, so committing it to output now would break chunk-invariance.
# "citation" mode holds the element body accumulated since the open literal
# (with the open literal itself already consumed). Invalid, oversized, and
# model-authored elements enter "discard" mode, which retains only a partial
# suffix of the closing literal it is waiting for.
CITATION_OPEN <- "<commons-citation>"
CITATION_CLOSE <- "</commons-citation>"
ASIDE_OPEN <- "<shiny-aside"
ASIDE_CLOSE <- "</shiny-aside>"
ELEMENT_BODY_CAP <- 16384L

citation_scanner <- function(corpus = list(), resolve = NULL) {
  if (is.null(resolve)) {
    resolve <- function(parsed) {
      if (is.null(parsed)) {
        return(list(
          html = "",
          decision = list(quote = NA_character_, status = "malformed")
        ))
      }
      render_citation_aside(parsed$quote, parsed$explanation, corpus)
    }
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

  # The flag tracks the *original* input stream, not what we chose to
  # output -- a rewritten <shiny-aside> replacement never changes whether
  # the next raw character was preceded by a newline.
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

  # One unit of progress: consume a complete open/close literal, handle a
  # cap overflow, or (failing that) flush everything except a live
  # hold-back and report that no further progress is possible without more
  # input. Returns TRUE if state changed such that re-running could make
  # more progress, FALSE otherwise.
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

    # mode == "discard": drop through the first matching close while retaining
    # only a possible partial close suffix. Nothing in this state is emitted.
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
      while (step()) {
        # keep making progress until a full feed's worth of buf is
        # resolved as far as it can be without more input
      }
      paste(out, collapse = "")
    },
    finish = function() {
      # Not reachable via the documented API (finish() is terminal), but
      # reset defensively so a stray extra feed()/finish() call after
      # finish() doesn't inherit a stale element mode.
      if (mode == "text") {
        flushed <- buf
        buf <<- ""
        return(flushed)
      }
      # Incomplete or discarded model markup must never reach the browser.
      buf <<- ""
      mode <<- "text"
      discard_close <<- NULL
      ""
    },
    decisions = function() decisions
  )
}

recorded_citation_resolver <- function(decisions) {
  index <- 0L
  resolve <- function(parsed) {
    index <<- index + 1L
    decision <- if (index <= length(decisions)) decisions[[index]] else NULL
    render_recorded_citation_aside(parsed, decision)
  }
  list(
    resolve = resolve,
    remaining = function() max(0L, length(decisions) - index)
  )
}

# The whole-string convenience form: a fresh scanner, fed once, finished.
# Canonical invariant: this output equals the concatenation of any
# chunking of the same text fed through feed()/finish().
project_citation_text <- function(text, corpus) {
  s <- citation_scanner(corpus)
  out <- paste0(s$feed(text), s$finish())
  list(text = out, decisions = s$decisions())
}

# Every `commons_tag` carried by a ContentToolResult in the turns appended
# since `from_index` (i.e. `turns[from_index:length(turns)]`) -- a read-only
# walk, never a mutation, so it's safe to call on `self$get_turns()` mid- or
# post-stream without disturbing ellmer's turn store.
collect_appended_tags <- function(turns, from_index) {
  if (from_index > length(turns)) {
    return(character())
  }
  appended <- turns[from_index:length(turns)]
  tags <- unlist(
    lapply(appended, function(turn) {
      lapply(turn@contents, function(content) {
        if (S7::S7_inherits(content, ellmer::ContentToolResult)) {
          content@extra$commons_tag
        }
      })
    }),
    use.names = FALSE
  )
  tags %||% character()
}

# Shared by commons.R's turn_has_user_message() and trajectory-review.R's
# turn_has_tool_result().
is_tool_result_content <- function(content) {
  S7::S7_inherits(content, ellmer::ContentToolResult)
}

# Earliest complete reserved literal in `buf`, or NULL. <commons-citation> is
# only a candidate at line start (true position 1 when `at_line_start`, or
# anywhere immediately after a "\n"); <shiny-aside> and stray reserved closes
# are candidates anywhere.
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

# Case-insensitive fixed-string search for a close literal anywhere in
# `buf`; returns a 1-indexed start position, or NA.
find_ci <- function(buf, literal) {
  pos <- regexpr(tolower(literal), tolower(buf), fixed = TRUE)
  if (pos == -1) NA_integer_ else as.integer(pos)
}

# The earliest complete reserved-tag literal in a citation body. Only the
# expected citation close is valid; any other event abandons the element.
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

# The body length to compare against the cap when no complete close
# literal has been found yet: `buf`'s length minus whatever trailing
# suffix is still a live case-insensitive prefix candidate of the close
# literal itself. Without this, a close literal split across a feed()
# boundary (e.g. one call ending mid-way through "</commons-citation>")
# would inflate `nchar(buf)` past the cap with bytes that are about to
# resolve into the close tag, wrongly abandoning a body that is really
# well within the cap -- and a different chunking of the same input,
# where those same bytes arrive together, would not make that mistake.
# This is the exact mirror of holdback_length()'s job for open literals
# in "text" mode, just for the single close literal relevant to the
# current mode.
confirmed_body_len <- function(buf, close_literal) {
  holdback <- longest_valid_suffix(buf, close_literal, function(start) TRUE)
  nchar(buf) - holdback
}

# The longest trailing suffix of `buf` that is still a live candidate to
# complete into a reserved literal: a case-insensitive prefix match whose
# starting position also satisfies that literal's anchor.
# Only the tail matters -- any earlier lookalike whose next character
# already diverges from the literal is dead and was already flushed.
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

# TRUE if `suffix` (length `len`) case-insensitively equals the first `len`
# characters of `literal`.
is_ci_prefix <- function(suffix, literal, len) {
  identical(tolower(suffix), tolower(substr(literal, 1, len)))
}
