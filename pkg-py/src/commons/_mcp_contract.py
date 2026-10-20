"""The commons-compatible MCP success envelope, used at both wire boundaries."""

from typing import Any

EXECUTION_TAGS = {"trusted_calculation": "A", "ad_hoc_sql": "B", "metadata": None}

ENVELOPE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "required": ["data", "commons"],
    "additionalProperties": False,
    "properties": {
        "data": {},
        "commons": {
            "type": "object",
            "required": [
                "contract_version",
                "catalog_revision",
                "tool_id",
                "execution_kind",
                "provenance_tag",
                "sources",
                "applied_definitions",
                "evidence",
                "coverage",
            ],
            "additionalProperties": False,
            "properties": {
                "contract_version": {"const": "1"},
                "catalog_revision": {"type": "string", "minLength": 1},
                "tool_id": {"type": "string", "minLength": 1},
                "execution_kind": {
                    "enum": ["trusted_calculation", "ad_hoc_sql", "metadata"]
                },
                "provenance_tag": {"enum": ["A", "B", None]},
                "sources": {"type": "array", "items": {"type": "string"}},
                "applied_definitions": {"type": "array", "items": {"type": "string"}},
                "evidence": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["uri", "revision"],
                        "additionalProperties": False,
                        "properties": {
                            "uri": {"type": "string"},
                            "revision": {"type": "string"},
                        },
                    },
                },
                "coverage": {
                    "type": "object",
                    "required": ["truncated"],
                    "additionalProperties": False,
                    "properties": {"truncated": {"type": "boolean"}},
                },
            },
        },
    },
}
