output_paths <- bananarama::bananarama("inst/hex/bananarama.yaml", force = TRUE)
output_path <- output_paths[[1]]
existing_paths <- list.files(dirname(output_path), "^commons-[0-9]+\\.png$", full.names = TRUE)
existing_indices <- as.integer(sub("^commons-([0-9]+)\\.png$", "\\1", basename(existing_paths)))
next_index <- max(c(existing_indices, 0)) + 1
file.rename(output_path, file.path(dirname(output_path), paste0("commons-", next_index, ".png")))
