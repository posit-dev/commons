# commons (development version)

* `commons()` gains a `mode` argument. With `mode = "trusted only"`, the agent answers only with trusted calculations. It never writes its own SQL or R, and it tells the user when no trusted calculation answers a question. These answers carry no provenance markers.

* The CSS classes on `run_r`'s display are now `commons-run-display`, `commons-run-details`, `commons-run-code`, and `commons-run-plot`, without the `-r`, because the Python package's code tool uses the same classes. App CSS that targets the old `commons-run-r-*` names needs updating.

# commons 0.1.1

* Fixes an issue with the R code sandbox where the generated policy would be
  too long when there were thousands of R packages installed.

* A number of improvements to documentation.

# commons 0.1.0

* Initial release.
