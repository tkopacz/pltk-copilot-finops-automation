#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE_INPUT=""
OUTPUT_ENV_FILE="${GITHUB_ENV:-}"
OUTPUT_SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-file)
      CONFIG_FILE_INPUT="$2"
      shift 2
      ;;
    --dry-run)
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

# This resolver is file-based only. Issue-based config testing goes through the
# unified apply-copilot-finops.yml workflow (scripts/resolve-copilot-finops-config.sh).

# Emit the validate-config type for the resolved file: v2 merged files validate
# with 'all', v1 member files with 'teams'. Keeps the workflow validate step thin.
config_version="$(yq eval '.version // 1' "$resolved_config_file" 2>/dev/null || echo 1)"
if [[ "$config_version" == "2" ]]; then
  resolved_config_type="all"
else
  resolved_config_type="teams"
fi

# Deprecation: the tracked default is now config/copilot-finops.yml (v2). v1 split files are
# still accepted but deprecated. Surface a notice when a v1 file is resolved.
deprecation_note=""
if [[ "$config_version" != "2" ]]; then
  deprecation_note="v1 split config files are deprecated; migrate to config/copilot-finops.yml (v2) with scripts/migrate-v1-to-v2.sh."
  echo "DEPRECATION: $deprecation_note" >&2
fi

{
  echo "COST_CENTER_MEMBERS_CONFIG_FILE=$resolved_config_file"
  echo "COST_CENTER_MEMBERS_CONFIG_TYPE=$resolved_config_type"
  echo "COST_CENTER_MEMBERS_CONFIG_SOURCE=$resolved_config_source"
} >>"$OUTPUT_ENV_FILE"

{
  echo "## Cost center members config"
  echo
  echo "- **Source:** $resolved_config_source"
  echo "- **Resolved file:** \`$resolved_config_file\`"
  if [[ -n "$deprecation_note" ]]; then
    echo "- **⚠️ Deprecation:** $deprecation_note"
  fi
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
