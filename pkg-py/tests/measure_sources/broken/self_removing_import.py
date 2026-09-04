"""Deletes its own sys.modules entry, then raises.

Regression fixture for _load_module_from_path's cleanup: it must not turn
this into a KeyError and swallow the real import error.
"""

import sys

del sys.modules[__name__]

raise RuntimeError("boom")
