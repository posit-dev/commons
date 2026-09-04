"""Shares a file name with the parent directory's orders.py on purpose.

Directory loading must not reach it, and loading it explicitly must not
collide with the other orders.py in sys.modules.
"""

from commons._measures import measure


@measure(description="Count of nested orders.")
def nested_order_count() -> int:
    return 1
