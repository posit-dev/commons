"""What runs inside the worker process, and nothing else.

The modules here restrict the process they are used from: they lower
resource limits, engage a sandbox on it, and take over stdout. Importing one
is inert and the parent does read a capability probe from here, but calling
anything that restricts belongs in the child. Nothing here imports
``commons``, which is what lets the worker be launched by absolute path on
an interpreter that has never heard of the package.
"""
