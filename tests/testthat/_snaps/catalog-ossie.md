# Apache Ossie versions and relationship references fail closed

    Code
      catalog_from_ossie(list(version = "9.9", semantic_model = list()))
    Condition
      Error:
      ! Apache Ossie version "9.9" is not supported.

---

    Code
      catalog_from_ossie(invalid)
    Condition
      Error:
      ! An Apache Ossie relationship is incomplete or refers to an unknown dataset.

