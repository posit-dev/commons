# catalog validation rejects dangling references

    Code
      new_commons_catalog(sources = list(source), relations = list(relation))
    Condition
      Error:
      ! Catalog entity "relation:test" has unknown source_id reference: "source:missing".

# dictionary projection rejects ambiguous table names

    Code
      catalog_to_data_dictionary(catalog)
    Condition
      Error:
      ! Catalog relations cannot be projected to a data dictionary because table names are ambiguous: "orders".

