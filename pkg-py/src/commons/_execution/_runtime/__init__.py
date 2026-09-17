"""What runs inside the worker process, and nothing else.

Modules here are for the worker to run against itself: lowering resource
limits, engaging a sandbox, taking over stdout. Importing one from the parent
would restrict the parent. Nothing here imports ``commons``, which is what
lets the worker be launched by absolute path on an interpreter that has never
heard of the package.
"""
