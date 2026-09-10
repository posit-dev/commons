"""The card a measure result draws: its metadata, its arguments, its value.

`www/commons-chat/commons-chat.css` styles these class names, and both
packages serve that one stylesheet, so the class names are the contract
these tests hold. The markup is rendered rather than inspected as tags,
because escaping is the part worth proving.
"""

from typing import Any

import pandas as pd

from commons._display import measure_display_html, measure_source_footer
from commons._rows import MAX_MARKDOWN_ROWS


def rendered(tag: Any) -> str:
    return str(tag) if tag is None else tag.get_html_string()


def test_a_value_is_shown_as_the_result() -> None:
    html = rendered(measure_display_html({}, 41))

    assert "commons-measure-result-value" in html
    assert "41" in html


def test_an_argument_is_labelled_and_shown() -> None:
    html = rendered(measure_display_html({"region_name": "EMEA"}, 41))

    assert "Region name" in html
    assert "EMEA" in html


def test_a_measure_with_no_arguments_draws_no_argument_block() -> None:
    assert "commons-measure-args" not in rendered(measure_display_html({}, 41))


def test_a_large_number_is_grouped_for_reading() -> None:
    html = rendered(measure_display_html({"floor": 1234567}, 41))

    assert "1,234,567" in html


def test_a_frame_is_drawn_as_a_table() -> None:
    frame = pd.DataFrame({"region": ["EMEA"], "revenue": [500.0]})

    html = rendered(measure_display_html({}, frame))

    assert "<table" in html
    assert "EMEA" in html


def test_a_measures_title_and_description_head_the_card() -> None:
    html = rendered(
        measure_display_html({}, 41, title="Net revenue", description="After refunds.")
    )

    assert "Net revenue" in html
    assert "After refunds." in html


def test_markup_in_a_value_is_shown_rather_than_rendered() -> None:
    html = rendered(measure_display_html({}, "<script>alert(1)</script>"))

    assert "<script>" not in html
    assert "&lt;script&gt;" in html


def test_markup_in_an_argument_is_shown_rather_than_rendered() -> None:
    html = rendered(measure_display_html({"region": "<b>EMEA</b>"}, 41))

    assert "<b>EMEA</b>" not in html


def test_a_measure_with_no_source_links_gets_no_footer() -> None:
    assert measure_source_footer(()) is None
    assert measure_source_footer(("Derived from the finance handbook.",)) is None


def test_one_source_link_is_named_plainly() -> None:
    html = rendered(measure_source_footer(("https://example.com/handbook",)))

    assert "View source" in html
    assert 'href="https://example.com/handbook"' in html


def test_several_source_links_are_numbered() -> None:
    html = rendered(
        measure_source_footer(("https://example.com/a", "https://example.com/b"))
    )

    assert "Source 1" in html
    assert "Source 2" in html


def test_a_link_opens_away_from_the_app() -> None:
    """A chat app loses its session if a link navigates the page."""
    html = rendered(measure_source_footer(("https://example.com/a",)))

    assert 'target="_blank"' in html
    assert "noopener" in html


def test_query_rows_are_drawn_as_a_table() -> None:
    """`call_metrics` hands its result over as rows, not as a frame."""
    rows = [{"region": "EMEA", "revenue": 500.0}]

    html = rendered(measure_display_html({}, rows))

    assert "<table" in html
    assert "EMEA" in html


def test_a_long_table_is_capped_and_says_so() -> None:
    rows = [{"n": n} for n in range(MAX_MARKDOWN_ROWS + 5)]

    html = rendered(measure_display_html({}, rows))

    assert html.count("<tr") == MAX_MARKDOWN_ROWS + 1
    assert "5 more rows not shown" in html


def test_a_column_a_row_omits_is_still_a_column() -> None:
    """A driver may leave a null column out of a row it returns."""
    html = rendered(measure_display_html({}, [{"a": 1}, {"a": 2, "b": 3}]))

    assert "<th>b</th>" in html


def test_an_argument_that_was_not_given_is_left_out() -> None:
    html = rendered(measure_display_html({"metrics": ["revenue"], "filters": None}, 41))

    assert "Filters" not in html
