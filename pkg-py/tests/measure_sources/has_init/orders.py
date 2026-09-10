from commons._measures import measure


@measure(description="Count of orders.")
def has_init_measure() -> int:
    return 1
