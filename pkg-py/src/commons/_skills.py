"""The built-in skills an agent can load on demand.

Each skill is a directory under `prompts/skills/` holding a `SKILL.md` in the
Agent Skills format: YAML frontmatter with a name and description, then the
instructions. Only the name and description reach the model until it loads one.
"""

from __future__ import annotations

from dataclasses import dataclass

import yaml

from ._prompt import _PROMPTS


@dataclass(frozen=True)
class Skill:
    name: str
    description: str
    topic: str
    body: str


def builtin_skills() -> dict[str, Skill]:
    """The packaged skills, keyed by name, in directory order."""
    dirs = sorted(
        (entry for entry in (_PROMPTS / "skills").iterdir() if entry.is_dir()),
        key=lambda entry: entry.name,
    )
    skills = [
        _read_skill(entry.joinpath("SKILL.md").read_text("utf-8")) for entry in dirs
    ]
    return {skill.name: skill for skill in skills}


def _read_skill(text: str) -> Skill:
    _, frontmatter, body = text.split("---\n", 2)
    meta = yaml.safe_load(frontmatter)
    return Skill(
        name=meta["name"],
        description=meta["description"],
        topic=meta["metadata"]["topic"],
        body=body.strip(),
    )
