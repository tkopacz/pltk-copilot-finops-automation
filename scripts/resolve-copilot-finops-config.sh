#!/usr/bin/env bash
set -euo pipefail

# Config resolver for the unified merged v2 Copilot FinOps workflow
# (.github/workflows/apply-copilot-finops.yml). Resolves the merged v2 config
# (config/copilot-finops.yml), validates it is a v2 merged document, and emits
# the COPILOT_FINOPS_* env vars + a job-summary block. The two parallel
# apply/sync jobs consume the same resolved file, so resolution happens once.
#
# This workflow is file-based: the enterprise slug and all policies come from the
# merged v2 config. An optional --issue-number resolves config from a
# config-request issue for TESTING ONLY (schedules never set it); the issue must
# carry the copilot-finops-config label and one merged v2 document.

CONFIG_FILE_INPUT=""
ISSUE_NUMBER=""
OUTPUT_ENV_FILE="${GITHUB_ENV:-}"
OUTPUT_SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-file)
      CONFIG_FILE_INPUT="$2"
      shift 2
      ;;
    --issue-number)
      ISSUE_NUMBER="$2"
      shift 2
      ;;
    --env-file)
      OUTPUT_ENV_FILE="$2"
      shift 2
      ;;
    --summary-file)
      OUTPUT_SUMMARY_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CONFIG_FILE_INPUT" ]]; then
  echo "ERROR: --config-file is required" >&2
  exit 1
fi
if [[ -z "$OUTPUT_ENV_FILE" ]]; then
  echo "ERROR: --env-file or GITHUB_ENV is required" >&2
  exit 1
fi
if [[ -z "$OUTPUT_SUMMARY_FILE" ]]; then
  echo "ERROR: --summary-file or GITHUB_STEP_SUMMARY is required" >&2
  exit 1
fi

resolved_config_file="$CONFIG_FILE_INPUT"
resolved_config_source="file: $CONFIG_FILE_INPUT"
resolved_config_from_issue="false"
issue_url=""
issue_updated_at=""
config_sha256=""

# TESTING ONLY: when an issue number is given, resolve the config from a
# config-request issue instead of the tracked file. The issue must carry the
# copilot-finops-config label and one fenced YAML block under the unified
# "Copilot FinOps config YAML" field. Because v2 is one merged document, there is
# no per-kind branching: whichever of the two lists the user omits simply makes
# that downstream job a friendly no-op.
if [[ -n "$ISSUE_NUMBER" ]]; then
  issue_json="$RUNNER_TEMP/copilot-finops-issue.json"
  issue_body="$RUNNER_TEMP/copilot-finops-issue.md"
  resolved_config_file="$RUNNER_TEMP/copilot-finops.yml"

  gh issue view "$ISSUE_NUMBER" --json number,title,state,url,updatedAt,labels,body >"$issue_json"
  jq -r '.body' "$issue_json" >"$issue_body"

  if [[ "$(jq -r '.state' "$issue_json")" != "OPEN" ]]; then
    echo "ERROR: Issue #$ISSUE_NUMBER must be open." >&2
    exit 1
  fi

  if [[ "$(jq -r 'any(.labels[].name; . == "copilot-finops-config")' "$issue_json")" != "true" ]]; then
    echo "ERROR: Issue #$ISSUE_NUMBER must have the copilot-finops-config label." >&2
    exit 1
  fi
  issue_section="Copilot FinOps config YAML"

  awk -v section="### $issue_section" '
    BEGIN { in_section=0; in_fence=0 }
    $0 ~ "^" section "[[:space:]]*$" { in_section=1; next }
    in_section && /^### / && !in_fence { exit }
    in_section && /^```/ {
      if (!in_fence) { in_fence=1; next }
      exit
    }
    in_section && in_fence { print }
  ' "$issue_body" >"$resolved_config_file"

  if [[ ! -s "$resolved_config_file" ]]; then
    echo "ERROR: Could not extract a fenced YAML block from the '$issue_section' issue field." >&2
    exit 1
  fi

  resolved_config_source="issue #$ISSUE_NUMBER (testing): $issue_section"
  resolved_config_from_issue="true"
  issue_url="$(jq -r '.url' "$issue_json")"
  issue_updated_at="$(jq -r '.updatedAt' "$issue_json")"
  config_sha256="$(shasum -a 256 "$resolved_config_file" | awk '{print $1}')"
fi

if [[ ! -f "$resolved_config_file" ]]; then
  echo "ERROR: Config file does not exist: $resolved_config_file" >&2
  exit 1
fi

# The unified workflow runs both apply and sync against ONE merged file, so it
# requires the v2 contract. Reject a v1 split file early with a clear message
# (use the per-type apply-user-budgets / sync-cost-center-members workflows for v1).
config_version="$(yq eval '.version // 1' "$resolved_config_file" 2>/dev/null || echo 1)"
if [[ "$config_version" != "2" ]]; then
  echo "ERROR: the unified workflow requires the v2 merged config (version: 2); got version $config_version in $resolved_config_file" >&2
  echo "HINT: use config/copilot-finops.yml (v2), or run the per-type apply-user-budgets / sync-cost-center-members workflows for v1 split files." >&2
  exit 1
fi
resolved_config_type="all"

{
  echo "COPILOT_FINOPS_CONFIG_FILE=$resolved_config_file"
  echo "COPILOT_FINOPS_CONFIG_TYPE=$resolved_config_type"
  echo "COPILOT_FINOPS_CONFIG_SOURCE=$resolved_config_source"
} >>"$OUTPUT_ENV_FILE"

{
  echo "## Copilot FinOps config"
  echo
  echo "- **Source:** $resolved_config_source"
  echo "- **Version:** v$config_version (merged budgets + member mappings)"
  if [[ "$resolved_config_from_issue" == "true" ]]; then
    echo "- **Issue:** $issue_url"
    echo "- **Issue updated at:** $issue_updated_at"
    echo "- **Config SHA-256:** \`$config_sha256\`"
  fi
  echo "- **Resolved file:** \`$resolved_config_file\`"
  echo
  echo "<details><summary>Config YAML</summary>"
  echo
  echo '```yaml'
  cat "$resolved_config_file"
  echo '```'
  echo
  echo "</details>"
  echo
} >>"$OUTPUT_SUMMARY_FILE"
