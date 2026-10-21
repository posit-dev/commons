#!/usr/bin/env bash
# Decide whether a live warehouse job has anything to test.
#
# The live tests skip when a required variable is unset, so a job missing one
# would pass having tested nothing. Writes run=false to $GITHUB_OUTPUT when
# none of the backend's required variables are set, run=true when all are, and
# fails when only some are.
#
#   .github/scripts/live-warehouse-configured.sh snowflake
set -euo pipefail

backend="$1"
contract="$(dirname "$0")/../../tests/shared/live-warehouse-env.json"
names=$(jq -r --arg b "$backend" \
  '.backends[$b] | .connection.required[], .fixtures.schema.variable' "$contract")

missing=()
for name in $names; do
  [ -n "${!name:-}" ] || missing+=("$name")
done

total=$(echo "$names" | wc -w)
if [ "${#missing[@]}" -eq "$total" ]; then
  echo "::notice::$backend is not configured for this repository; skipping."
  echo "run=false" >> "${GITHUB_OUTPUT:-/dev/stdout}"
elif [ "${#missing[@]}" -gt 0 ]; then
  echo "::error::$backend is partly configured. Missing: ${missing[*]}"
  exit 1
else
  echo "run=true" >> "${GITHUB_OUTPUT:-/dev/stdout}"
fi
