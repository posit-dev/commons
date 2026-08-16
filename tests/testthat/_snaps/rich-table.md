# rich_table requires model content to be a single string

    Code
      rich_table("table", html = "<table></table>", model_content = c("one", "two"))
    Condition
      Error in `rich_table()`:
      ! `model_content` must be a single string, not a character vector.

