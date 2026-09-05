"""Raises at import time, to test that a failed load does not dirty sys.modules.

Lives in a subdirectory so a non-recursive directory scan never reaches it.
"""

raise RuntimeError("boom")
