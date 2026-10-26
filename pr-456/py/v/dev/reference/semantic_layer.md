## semantic_layer()


Collect measures into a semantic layer.


Usage

``` python
semantic_layer(*items)
```


Each item is a measure, a list (or tuple) of measures, a module, or a path to a Python file or a directory of them. Directory searches are not recursive.

A sibling file is imported by plain absolute import; its directory is on sys.path only while the file loads. Even a single requested file puts its whole directory on sys.path, so every .py file beside it - and every subdirectory, which is importable as a package - is checked: a name that collides with the standard library, an installed package, or a module already imported from elsewhere is a construction error. A sibling imported this way stays in sys.modules under its bare name for the rest of the process, so two directories that each define a same-named helper cannot both be loaded in one process.

Collecting the same measure twice - the same file passed alongside its own directory, say - is not an error; two different measures sharing one name is. The R implementation is stricter here: it rejects a repeated name even when it is the same measure twice.
