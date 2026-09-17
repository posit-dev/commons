"""Code that runs inside the worker process.

Each module here changes the process that runs it: lowering resource
limits, engaging a sandbox, taking over stdout, and so on. The worker runs
them against itself. The parent never imports them, because that would affect
the parent's resources. None of these modules imports ``commons``: the
worker loads them by absolute path, on an interpreter that will not have
commons installed.
"""
