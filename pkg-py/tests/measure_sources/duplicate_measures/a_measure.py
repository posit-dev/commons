from commons._measures import measure


@measure(description="First of two distinct measures named dup.", name="dup")
def dup_from_a() -> int:
    return 1
