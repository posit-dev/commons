"""Named after a standard library module on purpose: loading this must fail
before the directory ever goes on sys.path.
"""

from commons._measures import measure


@measure(description="Should never load.")
def unreachable_measure() -> int:
    return 1
