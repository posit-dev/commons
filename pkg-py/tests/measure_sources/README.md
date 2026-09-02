Two traps for the next person editing this directory: the top level is
itself a fixture case, so adding any `.py` file here changes the expected
measure list in `test_semantic_layer_reads_a_directory_without_recursing`;
and the collision check scans every sibling file, so adding a top-level file
named after any importable module breaks every path-loading test at once.
