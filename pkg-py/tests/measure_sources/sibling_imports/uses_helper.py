"""Imports a sibling file by plain absolute import, the way an ordinary
Python module does.
"""

from helper_lib import double  # type: ignore[missing-import]

from commons import measure


@measure(description="Doubled count.")
def doubled_count() -> int:
    return double(21)
