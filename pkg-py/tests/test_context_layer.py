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
