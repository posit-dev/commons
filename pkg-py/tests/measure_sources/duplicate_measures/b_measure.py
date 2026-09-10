from commons._measures import measure


@measure(description="Second of two distinct measures named dup.", name="dup")
def dup_from_b() -> int:
    return 2
