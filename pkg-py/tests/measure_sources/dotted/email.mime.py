from commons._measures import measure


@measure(description="A measure in a file whose name carries a dot.")
def dotted_measure() -> int:
    return 1
