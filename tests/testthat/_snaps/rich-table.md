# rich_table requires model-facing data to be a data frame

    Code
      rich_table("table", data = 1, html = "<table></table>")
    Condition
      Error in `rich_table()`:
      ! `data` must be a data frame.

