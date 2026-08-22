"""Placeholder so `pytest` collects at least one test.

pytest exits 5 ("no tests collected") on an empty suite, which CI reads as a
failure. The scaffold task deletes this file when it lands real tests.
"""


def test_placeholder() -> None:
    assert True
