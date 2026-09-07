"""What an agent's answers can be cited against, driven by the shared fixture.

The labels, the kinds, and the order entries are added in are a cross-language
contract, so the cases live in ``tests/shared/citation-corpus.json`` and the R
suite runs the same ones. Do not restate a case here; add it to the fixture.
"""

import inspect
from typing import Any

import pandas as pd
import pytest

from commons import ContextLayer, data_source
from commons._citations import build_citation_corpus, match_citation
from commons._data_dictionary import DataDictionary
from commons._data_source import DataSource
from commons._measures import Injected, Measure, as_measure, measure

from ._shared import load_shared_fixture

CASES: list[dict[str, Any]] = load_shared_fixture("citation-corpus")[
    "build_citation_corpus"
]["cases"]


def _fixture_measure(spec: dict[str, Any]) -> Measure:
    """Build a measure from a fixture spec through the production decorator.

    Every argument a case declares is commons-supplied, so the generated
    function carries an ``Injected`` annotation per name and no model-visible
    arguments at all: what the corpus needs from a measure is the block
    ``search_pool`` renders, and measure-schema.json pins the arguments half
    of that block already.
    """

    def func(*args: Any, **kwargs: Any) -> None:
        return None

    injected: list[str] = spec.get("injected") or []
    func.__name__ = spec["name"]
    func.__annotations__ = {name: Injected[Any] for name in injected}
    func.__signature__ = inspect.Signature(  # type: ignore[attr-defined]
        [
            inspect.Parameter(
                name, inspect.Parameter.POSITIONAL_OR_KEYWORD, annotation=Injected[Any]
            )
            for name in injected
        ]
    )
    record = as_measure(measure(description=spec["description"])(func))
    assert record is not None
    return record


def _fixture_source(spec: dict[str, Any]) -> DataSource:
    """A real source over an in-memory DuckDB, carrying the case's dictionary."""
    dictionary = (
        None
        if spec["dictionary"] is None
        else DataDictionary.model_validate(spec["dictionary"])
    )
    return data_source(sales=pd.DataFrame({"revenue": [1.0]}), dictionary=dictionary)


def test_the_fixture_is_not_empty() -> None:
    # An empty case list would make the parametrized test below vacuously pass.
    assert CASES


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["name"])
def test_the_corpus_matches_the_shared_fixture(case: dict[str, Any]) -> None:
    layer = None if case["docs"] is None else ContextLayer(case["docs"])
    measures = [_fixture_measure(spec) for spec in case["measures"]]
    sources = {spec["name"]: _fixture_source(spec) for spec in case["sources"]}

    corpus = build_citation_corpus(layer, measures, sources)

    assert [(entry.label, entry.kind) for entry in corpus] == [
        (entry["label"], entry["kind"]) for entry in case["expected"]
    ]
    for want in case["matches"]:
        found = match_citation(want["quote"], corpus)
        label = found.label if found is not None else None
        assert label == want["label"], want["quote"]


def test_every_entry_carries_the_text_it_was_built_from() -> None:
    # The fixture pins labels and order; an entry with no text would still
    # satisfy it, and would silently make its source uncitable.
    dictionary = DataDictionary.model_validate({"details": "Revenue excludes tax."})
    source = data_source(sales=pd.DataFrame({"revenue": [1.0]}), dictionary=dictionary)

    corpus = build_citation_corpus(ContextLayer(["A note."]), [], {"sales_db": source})

    assert [entry.text for entry in corpus] == ["Revenue excludes tax.", "A note."]
