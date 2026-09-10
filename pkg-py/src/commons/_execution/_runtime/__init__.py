"""Code that runs inside the worker process.

Each module here changes the process that runs it: lowering resource
limits, engaging a sandbox, taking over stdout, and so on. The worker runs
them against itself. Importing one is inert, and the parent reads a
capability probe from here, but the functions that change the process
belong in the child: calling one from the parent would affect the parent's
resources. None of these modules imports ``commons``: the worker loads
them by absolute path, on an interpreter that will not have commons
installed.
"""
