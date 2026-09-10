from commons._measures import measure


@measure(description="Count of orders.")
def aliased_measure() -> int:
    return 1


# Re-exporting a measure under a second name in the same module is one
# measure, not a name collision.
also_known_as = aliased_measure
