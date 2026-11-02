from commons._skills import builtin_skills
from tests._shared import load_shared_fixture


def test_skills_are_offered_beside_the_tools_the_shared_cases_say() -> None:
    for case in load_shared_fixture("skills")["cases"]:
        assert list(builtin_skills(case["tools"])) == case["offered"], case["name"]
