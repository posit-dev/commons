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

# relative authored table names must be unambiguous

    Code
      catalog_merge_dictionary(dictionary, relations, NULL, function(...) NULL,
      "upper")
    Condition
      Error:
      ! Authored table "orders" matches more than one selected relation: "ANALYTICS.PUBLIC.ORDERS" and "ANALYTICS.STAGING.ORDERS".
      i Use its fully qualified name in the data dictionary.

