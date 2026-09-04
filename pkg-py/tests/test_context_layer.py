import time
from concurrent.futures import ThreadPoolExecutor

import pandas as pd
import pytest
from raghilda.store import DuckDBStore

from commons import ContextLayer, context_layer, data_source
from commons._context_layer import (
    _dictionary_chunks,
    augment_context_layer,
    strip_frontmatter,
)
from commons._data_dictionary import DataDictionary

from ._shared import load_shared_fixture

SHARED = load_shared_fixture("context_layer")


# An empty case list would make the parametrized test below vacuously pass.
def test_the_fixture_is_not_empty():
    assert SHARED["strip_frontmatter"]["cases"]


@pytest.mark.parametrize(
    "case", SHARED["strip_frontmatter"]["cases"], ids=lambda c: c["name"]
)
def test_strip_frontmatter_shared_cases(case):
    assert strip_frontmatter(case["input"]) == case["expected"]


def test_context_layer_reads_files_and_strips_frontmatter(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("---\nprovenance: abc1234\n---\n# Revenue\nRevenue excludes tax.")

    layer = context_layer(files=[path])

    assert layer.docs == ("# Revenue\nRevenue excludes tax.",)


def test_context_layer_skips_a_frontmatter_only_file(tmp_path):
    path = tmp_path / "meta.md"
    path.write_text("---\nprovenance: some-source\n---\n")

    assert context_layer(files=[path]).docs == ()


def test_context_layer_drops_the_final_line_ending(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue\n")

    assert context_layer(files=[path]).docs == ("# Revenue",)


def test_context_layer_defaults_to_no_documents():
    assert context_layer().docs == ()
    assert isinstance(context_layer(), ContextLayer)


def test_context_layer_fails_at_construction_on_a_bad_path(tmp_path):
    missing = tmp_path / "nope.md"

    with pytest.raises(FileNotFoundError, match=str(missing)):
        context_layer(files=[missing])


def test_context_layer_rejects_a_bare_string(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue")

    with pytest.raises(TypeError, match="files"):
        context_layer(files=str(path))


def test_context_layer_repr_counts_documents(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue")

    assert repr(context_layer()) == "<ContextLayer: 0 documents>"
    assert repr(context_layer(files=[path])) == "<ContextLayer: 1 document>"


def test_search_finds_a_relevant_chunk(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text(
        "# Revenue\nRevenue excludes tax unless stated otherwise.\n\n"
        "# Discounts\nDiscounts are applied before tax."
    )

    hits = context_layer(files=[path]).search("what does revenue mean")

    assert len(hits) >= 1
    assert "tax" in hits[0]


def test_search_returns_nothing_when_the_layer_is_empty():
    assert context_layer().search("anything") == []


def test_search_returns_nothing_when_no_chunk_matches(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# A\napples")

    assert context_layer(files=[path]).search("zzzzz") == []


def test_search_does_not_surface_stripped_frontmatter(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text(
        "---\nprovenance: abc1234\n---\n"
        "# Revenue\nRevenue excludes tax unless stated otherwise."
    )

    layer = context_layer(files=[path])

    assert "tax" in layer.search("revenue")[0]
    assert layer.search("abc1234") == []


def test_search_reuses_the_store_across_calls(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue\nRevenue excludes tax.")
    layer = context_layer(files=[path])

    layer.search("revenue")
    first = layer._store_cache
    layer.search("revenue")

    assert first is not None
    assert layer._store_cache is first


def test_search_indexes_every_document(tmp_path):
    first = tmp_path / "a.md"
    first.write_text("# Revenue\nRevenue excludes tax.")
    second = tmp_path / "b.md"
    second.write_text("# Discounts\nDiscounts are applied before tax.")

    layer = context_layer(files=[first, second])

    assert "Discounts" in layer.search("discounts")[0]
    assert "Revenue" in layer.search("revenue")[0]


def test_search_indexes_identical_documents_separately(tmp_path):
    first = tmp_path / "a.md"
    first.write_text("# Revenue\nRevenue excludes tax.")
    second = tmp_path / "b.md"
    second.write_text("# Revenue\nRevenue excludes tax.")

    layer = context_layer(files=[first, second])

    assert len(layer.search("revenue", top_k=5)) == 2


def test_search_respects_top_k(tmp_path):
    for i in range(5):
        (tmp_path / f"{i}.md").write_text(f"# Revenue {i}\nRevenue excludes tax.")

    layer = context_layer(files=sorted(tmp_path.glob("*.md")))

    assert len(layer.search("revenue", top_k=2)) == 2


def test_prewarm_builds_the_store_ahead_of_search(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue\nRevenue excludes tax.")
    layer = context_layer(files=[path])

    assert layer._store_cache is None
    layer.prewarm()

    assert layer._store_cache is not None
    assert layer._store_cache.size() == 1


def test_prewarm_on_an_empty_layer_builds_nothing():
    layer = context_layer()
    layer.prewarm()

    assert layer._store_cache is None


def test_prewarm_is_idempotent(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue\nRevenue excludes tax.")
    layer = context_layer(files=[path])

    layer.prewarm()
    first = layer._store_cache
    layer.prewarm()

    assert layer._store_cache is first


def test_search_rejects_a_non_positive_top_k(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue\nRevenue excludes tax.")
    layer = context_layer(files=[path])

    with pytest.raises(ValueError, match="top_k"):
        layer.search("revenue", top_k=0)


def test_search_results_are_the_same_after_prewarm(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text(
        "# Revenue\nRevenue excludes tax unless stated otherwise.\n\n"
        "# Discounts\nDiscounts are applied before tax."
    )

    cold = context_layer(files=[path]).search("revenue")
    warm_layer = context_layer(files=[path])
    warm_layer.prewarm()

    assert warm_layer.search("revenue") == cold


def test_concurrent_first_searches_build_one_store(tmp_path, monkeypatch):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue\nRevenue excludes tax.")
    layer = context_layer(files=[path])

    builds = 0
    real_create = DuckDBStore.create

    def counting_create(*args, **kwargs):
        nonlocal builds
        builds += 1
        time.sleep(0.05)  # widen the race window
        return real_create(*args, **kwargs)

    monkeypatch.setattr(DuckDBStore, "create", counting_create)

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: layer.search("revenue"), range(8)))

    assert builds == 1
    assert all(result == results[0] for result in results)


# An empty case list would make the parametrized test below vacuously pass.
def test_the_dictionary_chunk_fixture_is_not_empty():
    assert SHARED["dictionary_context_chunks"]["cases"]


@pytest.mark.parametrize(
    "case", SHARED["dictionary_context_chunks"]["cases"], ids=lambda c: c["name"]
)
def test_dictionary_context_chunks_shared_cases(case):
    spec = case["dictionary"]
    dictionary = None if spec is None else DataDictionary.model_validate(spec)

    assert _dictionary_chunks(dictionary) == case["expected"]


def a_source_with_dictionary(spec):
    """A real source over an in-memory DuckDB, carrying the given dictionary."""
    return data_source(
        notes=pd.DataFrame({"n": [1]}),
        dictionary=DataDictionary.model_validate(spec),
    )


def test_augment_appends_dictionary_chunks_to_a_new_layer(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue\nRevenue excludes tax.")
    layer = context_layer(files=[path])
    source = a_source_with_dictionary({"details": "Orders from the retail system."})

    augmented = augment_context_layer(layer, [source])

    assert augmented is not None
    assert augmented is not layer
    assert layer.docs == ("# Revenue\nRevenue excludes tax.",)
    assert augmented.docs == (
        "# Revenue\nRevenue excludes tax.",
        "Orders from the retail system.",
    )


def test_augment_creates_a_layer_when_there_was_none():
    source = a_source_with_dictionary({"details": "Orders from the retail system."})

    augmented = augment_context_layer(None, [source])

    assert augmented is not None
    assert augmented.docs == ("Orders from the retail system.",)


def test_augment_returns_the_argument_unchanged_when_there_is_nothing_to_add(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue\nRevenue excludes tax.")
    layer = context_layer(files=[path])
    bare = data_source(notes=pd.DataFrame({"n": [1]}))

    assert augment_context_layer(layer, [bare]) is layer
    assert augment_context_layer(None, [bare]) is None
    assert augment_context_layer(layer, []) is layer
    assert augment_context_layer(None, []) is None


def test_augment_gives_the_new_layer_a_fresh_store(tmp_path):
    path = tmp_path / "notes.md"
    path.write_text("# Revenue\nRevenue excludes tax.")
    layer = context_layer(files=[path])
    layer.prewarm()
    source = a_source_with_dictionary({"details": "Orders from the retail system."})

    augmented = augment_context_layer(layer, [source])

    assert augmented is not None
    assert augmented._store_cache is None
    assert "Orders" in augmented.search("orders retail")[0]


def test_augment_folds_in_every_source():
    first = a_source_with_dictionary({"details": "Orders from the retail system."})
    second = a_source_with_dictionary({"glossary": {"AOV": "Average order value."}})

    augmented = augment_context_layer(None, [first, second])

    assert augmented is not None
    assert augmented.docs == (
        "Orders from the retail system.",
        "AOV: Average order value.",
    )


def test_a_dictionary_alone_is_searchable_context():
    source = a_source_with_dictionary(
        {
            "details": None,
            "tables": {},
            "glossary": {"AOV": "Average order value, revenue divided by order count."},
        }
    )

    layer = augment_context_layer(None, [source])

    assert layer is not None
    assert layer.search("average order value") == [
        "AOV: Average order value, revenue divided by order count."
    ]
