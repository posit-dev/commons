from commons._measures import measure


@measure(description="Count of orders.")
def pkg_collision_measure() -> int:
    return 1
