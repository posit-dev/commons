"""The built-in skills an agent can load on demand.

Each skill is a directory under `prompts/skills/` holding a `SKILL.md` in the
Agent Skills format: YAML frontmatter with a name and description, then the
instructions. Only the name and description reach the model until it loads one.
A skill that `requires` a tool is offered only when that tool is registered.
"""

from __future__ import annotations

from collections.abc import Collection
from dataclasses import dataclass

import yaml

from ._prompt import _PROMPTS


@dataclass(frozen=True)
class Skill:
    name: str
    description: str
    topic: str
    requires: str | None
    body: str


def builtin_skills(tool_names: Collection[str] = ()) -> dict[str, Skill]:
    """The packaged skills the given tools support, keyed by name."""
    dirs = sorted(
        (entry for entry in (_PROMPTS / "skills").iterdir() if entry.is_dir()),
        key=lambda entry: entry.name,
    )
    skills = [
        _read_skill(entry.joinpath("SKILL.md").read_text("utf-8")) for entry in dirs
    ]
    return {
        skill.name: skill
        for skill in skills
        if skill.requires is None or skill.requires in tool_names
    }


def _read_skill(text: str) -> Skill:
    _, frontmatter, body = text.split("---\n", 2)
    meta = yaml.safe_load(frontmatter)
    return Skill(
        name=meta["name"],
        description=meta["description"],
        topic=meta["metadata"]["topic"],
        requires=meta["metadata"].get("requires"),
        body=body.strip(),
    )
