"""What runs inside the worker process, and nothing else.

Every module here mutates the process it is imported into: it lowers resource
limits, engages a sandbox on itself, and takes over stdout. Importing one from
the parent would restrict the parent. Nothing here imports ``commons``, which
is what lets the worker be launched by absolute path on an interpreter that
has never heard of the package.
"""
