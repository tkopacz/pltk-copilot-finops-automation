#!/usr/bin/env bash
# Schema unit tests for the versioned config JSON Schemas under schemas/.
#
# These tests exercise the SCHEMAS in isolation (structure, types, enums, and
# typo protection) with check-jsonschema, independent of the bash semantic
# cross-field rules in scripts/validate-config.sh. They are the contract tests
# for schemas/v<N>/.
#
# Layout (version-scoped, one manifest per schema):
#
#   tests/cases/<version>/<schema>.yml   e.g. tests/cases/v1/budget-policies.yml
#
# The runner discovers every tests/cases/v*/ directory, so cases under v1/ run
# against schemas/v1/ and a future v2/ runs against schemas/v2/ — no edits here.
# Each manifest is a list of cases:
#
#   cases:
#     - name: enterprise-minimal
#       valid: true
#       config: { budget_policies: [ { type: enterprise, budget: { amount: 5 } } ] }
#     - name: bad-type-enum
#       valid: false
#       expect_error: "is not one of"     # substring that must appear in output
#       config: { budget_policies: [ { type: nope, budget: { amount: 5 } } ] }
#
# Rules:
#   - valid: true   -> config MUST pass the schema.
#   - valid: false  -> config MUST be rejected (validator exit 1); if
#                      expect_error is set, that substring must appear in the
#                      output, so a case cannot fail for the wrong reason.
#   - Every *.schema.json under schemas/ is meta-validated as a valid JSON
#     Schema (per its declared $schema dialect: v1 draft-07, v2 draft 2020-12).
#
# To extend when a config field/feature changes (see AGENTS.md "Schema Tests"):
#   1. Update the matching schema under schemas/v<N>/.
#   2. Append a valid case and an invalid case (with expect_error) to
#      tests/cases/v<N>/<schema>.yml.
#   3. Run this script and keep it green.
#
# Usage:   tests/run-schema-tests.sh
# Requires: check-jsonschema (pipx install check-jsonschema) and yq.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_DIR="$REPO_ROOT/schemas"
CASES_DIR="$SCRIPT_DIR/cases"

missing=0
if ! command -v check-jsonschema >/dev/null 2>&1; then
  echo "ERROR: check-jsonschema is required to run schema tests." >&2
  echo "HINT: pipx install check-jsonschema   (or: pip install check-jsonschema)" >&2
  missing=1
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required to parse the test case manifests." >&2
  missing=1
fi
[[ $missing -eq 0 ]] || exit 1

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  GREEN=""; RED=""; BOLD=""; RESET=""
fi

pass=0
fail=0

report_pass() {
  pass=$((pass + 1))
  printf '  %sPASS%s %s\n' "$GREEN" "$RESET" "$1"
}

report_fail() {
  fail=$((fail + 1))
  printf '  %sFAIL%s %s\n' "$RED" "$RESET" "$1"
  if [[ -n "${2:-}" ]]; then
    printf '%s\n' "$2" | sed 's/^/        /'
  fi
}

CASE_JSON="$(mktemp)"
trap 'rm -f "$CASE_JSON"' EXIT

# ── Meta-validate every schema file as a valid JSON Schema ───────────────────
echo "${BOLD}== Meta-validating schema files (per each file's declared dialect) ==${RESET}"
schema_files=()
while IFS= read -r f; do
  schema_files+=("$f")
done < <(find "$SCHEMA_DIR" -type f -name '*.schema.json' | sort)

if [[ ${#schema_files[@]} -eq 0 ]]; then
  report_fail "no *.schema.json files found under $SCHEMA_DIR"
else
  for sf in "${schema_files[@]}"; do
    rel="${sf#"$REPO_ROOT"/}"
    if out="$(check-jsonschema --check-metaschema "$sf" 2>&1)"; then
      report_pass "valid JSON Schema: $rel"
    else
      report_fail "invalid JSON Schema: $rel" "$out"
    fi
  done
fi

# ── Run the cases in one manifest against its schema ─────────────────────────
run_manifest() {
  local case_file="$1" version="$2"
  local schema_name schema_file count i name valid expect out code
  schema_name="$(basename "$case_file" .yml)"
  schema_file="$SCHEMA_DIR/$version/$schema_name.schema.json"

  echo
  echo "${BOLD}== $schema_name ($version) ==${RESET}"

  if [[ ! -f "$schema_file" ]]; then
    report_fail "schema not found: ${schema_file#"$REPO_ROOT"/}"
    return
  fi

  count="$(yq eval '.cases | length' "$case_file" 2>/dev/null)"
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [[ "$count" -eq 0 ]]; then
    report_fail "$schema_name: no cases found in ${case_file#"$REPO_ROOT"/}"
    return
  fi

  for ((i = 0; i < count; i++)); do
    name="$(yq eval ".cases[$i].name // \"case-$i\"" "$case_file")"
    valid="$(yq eval ".cases[$i].valid" "$case_file")"
    expect="$(yq eval ".cases[$i].expect_error // \"\"" "$case_file")"

    # Extract the case config as JSON (unambiguous string/number typing) and
    # validate that document against the schema.
    if ! yq eval -o=json ".cases[$i].config" "$case_file" >"$CASE_JSON" 2>/dev/null; then
      report_fail "$name (could not extract .config)"
      continue
    fi

    case "$valid" in
      true)
        if out="$(check-jsonschema --schemafile "$schema_file" "$CASE_JSON" 2>&1)"; then
          report_pass "$name (valid)"
        else
          report_fail "$name (expected to pass)" "$out"
        fi
        ;;
      false)
        out="$(check-jsonschema --schemafile "$schema_file" "$CASE_JSON" 2>&1)"
        code=$?
        if [[ $code -eq 0 ]]; then
          report_fail "$name (expected rejection, but it passed schema)"
        elif [[ $code -ne 1 ]]; then
          report_fail "$name (validator errored, exit $code — case or schema problem?)" "$out"
        elif [[ -n "$expect" ]] && ! printf '%s' "$out" | grep -qF -- "$expect"; then
          report_fail "$name (rejected, but not for expected reason: '$expect')" "$out"
        else
          report_pass "$name (invalid)"
        fi
        ;;
      *)
        report_fail "$name (case must set 'valid: true' or 'valid: false', got '$valid')"
        ;;
    esac
  done
}

# ── Discover version dirs and run every manifest ─────────────────────────────
shopt -s nullglob
version_dirs=("$CASES_DIR"/v*/)
if [[ ${#version_dirs[@]} -eq 0 ]]; then
  report_fail "no version case directories found under ${CASES_DIR#"$REPO_ROOT"/}/ (expected v1/, v2/, ...)"
fi
for version_dir in "${version_dirs[@]}"; do
  version="$(basename "$version_dir")"
  manifests=("$version_dir"*.yml)
  if [[ ${#manifests[@]} -eq 0 ]]; then
    report_fail "$version: no case manifests (*.yml) found"
    continue
  fi
  for case_file in "${manifests[@]}"; do
    run_manifest "$case_file" "$version"
  done
done

echo
echo "─────────────────────────────────────────────"
printf '%sTotal: %d passed, %d failed%s\n' "$BOLD" "$pass" "$fail" "$RESET"
[[ $fail -eq 0 ]] || exit 1
