import pytest

from commons import ContextLayer, context_layer
from commons._context_layer import strip_frontmatter

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
