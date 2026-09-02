#!/usr/bin/env bash
# Regenerate the export-record half of tests/shared/definitions.json from the
# pinned data-dict binary.
#
# `export_records` is data-dict's own output, projected to the fields both
# packages consume. `mixed_grain` and `invalid` are not in that output:
# grain is derived from the typed IR, and the problem codes come from
# validate-spec. Both are hand-maintained and this script preserves them.
#
# The binary is the authority. Regenerating against a build from any other
# revision would quietly bless whatever that build does.
set -euo pipefail

commit="d950c5ac90d0ab939d330600f3a5ee1bfde0f604"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
corpus="$root/tests/shared/definition-export/valid"
out="$root/tests/shared/definitions.json"

if ! command -v data-dict >/dev/null; then
  echo "data-dict is not on PATH. Install it at the pinned commit:" >&2
  echo "  cargo install --git https://github.com/tidyverse/data-dict --rev $commit data-dict-cli" >&2
  exit 1
fi

installed="$(cargo install --list 2>/dev/null | grep -c "data-dict?rev=$commit" || true)"
if [ "$installed" -eq 0 ]; then
  echo "The data-dict on PATH was not built from $commit." >&2
  echo "A fixture generated from another revision is not authoritative." >&2
  exit 1
fi

python3 - "$commit" "$corpus" "$out" <<'PY'
import json
import pathlib
import subprocess
import sys

commit, corpus, out = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
existing = json.loads(out.read_text()) if out.exists() else {}

records = {}
for path in sorted(corpus.glob("*.yaml")):
    export = json.loads(
        subprocess.run(
            ["data-dict", "export-spec", str(path)],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
    )
    cases = {}
    for table in export.get("tables", []):
        for definition in table.get("definitions") or []:
            duckdb = next(
                (
                    item
                    for item in definition.get("translations") or []
                    if item.get("target") == "SQL(duckdb)"
                ),
                {},
            )
            cases[f"{table['name']}::{definition['name']}"] = {
                "expression": definition.get("expression"),
                "kind": definition.get("kind"),
                "type": definition.get("type"),
                "columns": definition.get("columns") or [],
                "definitions": definition.get("definitions") or [],
                "translation": {
                    "target": duckdb.get("target"),
                    "code": duckdb.get("code"),
                    "error": duckdb.get("error"),
                    "notes": duckdb.get("notes") or [],
                },
            }
    records[path.name] = cases

spec = {
    "data_dict_commit": commit,
    "corpus_dir": "definition-export",
    "export_records": records,
    "mixed_grain": existing.get("mixed_grain", {}),
    "invalid": existing.get("invalid", {}),
}
out.write_text(json.dumps(spec, indent=2, sort_keys=True) + "\n")
total = sum(len(cases) for cases in records.values())
print(f"Wrote {out.name} with {total} definitions from {len(records)} fixtures")
PY
