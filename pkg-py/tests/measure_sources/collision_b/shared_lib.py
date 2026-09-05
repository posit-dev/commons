"""Shares a file name with collision_a/shared_lib.py on purpose.

Loading anything from this directory must fail once collision_a's
shared_lib.py has already been imported under the bare name "shared_lib".
"""


def value() -> int:
    return 2
