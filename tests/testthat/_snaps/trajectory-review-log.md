# review state ignores unrelated Markdown and warns on bad reviews

    Code
      state <- read_review_state(review_dir)
    Condition
      Warning:
      Ignoring malformed trajectory review document.
      i '<review-dir>/conversation-bad.md'

