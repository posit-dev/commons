raise RuntimeError(
    "__init__.py in a measure directory must never be imported; "
    "a directory of measure files is not a package."
)
