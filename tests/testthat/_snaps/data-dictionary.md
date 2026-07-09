# tables and columns without names error

    Code
      new_data_dictionary(list(tables = list(list(description = "no name"))))
    Condition
      Error:
      ! Each table in a data dictionary needs a name.

---

    Code
      new_data_dictionary(list(tables = list(list(name = "sales", columns = list(list(
        type = "date"))))))
    Condition
      Error:
      ! Each column in a data dictionary needs a name.

# data_source() rejects other dictionary inputs

    Code
      data_source(sales = test_sales(), dictionary = 42)
    Condition
      Error in `data_source()`:
      ! `dictionary` must be a path to a data-dict.yaml file.

# dictionary content lands in the system prompt

    Code
      cat(dictionary_prompt_text(list(src)))
    Output
      
      # About the data
      
      ## retail sales
      
      Order and revenue data for a small retailer.
      
      Revenue figures exclude tax.
      
      Definitions of domain terms:
      
      - AOV: Average order value.
      - booked: An order is booked once payment clears.

# multi-source prompts label dictionary blocks by source

    Code
      cat(dictionary_prompt_text(sources))
    Output
      
      # About the data
      
      ## sales_db
      
      Order and revenue data for a small retailer.
      
      Revenue figures exclude tax.
      
      Definitions of domain terms:
      
      - AOV: Average order value.
      - booked: An order is booked once payment clears.

