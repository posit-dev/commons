"""The coding-agent skill ships complete in the installed package.

Users copy the skill out of the installed package into their coding agent's
skills directory, so a missing or misnamed file breaks their coding agent
without any error from commons. These tests read the skill the way a user
does, through `importlib.resources`.
"""

from __future__ import annotations

import re
from importlib.resources import files
from importlib.resources.abc import Traversable
from pathlib import Path

import yaml

SKILL = files("commons") / "skills" / "commons"

REFERENCES = (
    "onboarding",
    "data-dictionaries",
    "extracting-from-artifacts",
    "evaluation",
    "iterating-from-trajectories",
)

# Names from the R API and toolchain. Any of them in the Python skill sends a
# coding agent after a function or file that does not exist in Python.
R_TERMS = (
    "agent$",
    "commons$",
    "#' @",
    "roxygen",
    "DESCRIPTION",
    "rsconnect::",
    "system.file",
    "Sys.Date",
    "vitals",
    "devtools",
    "library(",
    "<-",
)

LINK = re.compile(r"\]\(((?:references/)?[\w-]+\.md)(?:#[\w-]*)?\)")


def _skill_files() -> list[Traversable]:
    references = SKILL / "references"
    return [SKILL / "SKILL.md", *(references / f"{name}.md" for name in REFERENCES)]


def test_skill_ships_with_the_package() -> None:
    text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
    _, frontmatter, _ = text.split("---", 2)
    meta = yaml.safe_load(frontmatter)
    assert meta["name"] == "commons"
    assert meta["description"].strip()


def test_skill_lists_each_reference() -> None:
    text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
    linked = {Path(link).stem for link in LINK.findall(text)}
    assert linked == set(REFERENCES)


def test_every_linked_reference_exists() -> None:
    for file in _skill_files():
        base = SKILL if file.name == "SKILL.md" else SKILL / "references"
        for link in LINK.findall(file.read_text(encoding="utf-8")):
            target = base.joinpath(*link.split("/"))
            assert target.is_file(), f"{file.name} links to missing {link}"


def test_skill_names_no_r_api() -> None:
    for file in _skill_files():
        text = file.read_text(encoding="utf-8")
        found = [term for term in R_TERMS if term in text]
        assert not found, f"{file.name} names R-only {found}"
