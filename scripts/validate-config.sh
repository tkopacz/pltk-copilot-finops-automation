#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${1:-}"
CONFIG_TYPE="${2:-}"

if [[ -z "$CONFIG_FILE" || -z "$CONFIG_TYPE" ]]; then
  echo "Usage: $0 <config-file> <teams|budgets|all>" >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file does not exist: $CONFIG_FILE" >&2
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: yq is required for config validation." >&2
  exit 1
fi

yq eval '.' "$CONFIG_FILE" >/dev/null

config_value() {
  yq eval "$1 // \"\"" "$CONFIG_FILE"
}

has_value() {
  [[ -n "$1" && "$1" != "null" ]]
}

has_key() {
  # True when the object at path $1 has key $2. Presence-based (matches the
  # schema's conditional forbidden-field rules), independent of the value.
  [[ "$(yq eval "$1 | has(\"$2\")" "$CONFIG_FILE")" == "true" ]]
}

read_default_true() {
  local expression="$1" value
  # Read raw (not via //) so explicit false stays false.
  value="$(yq eval "$expression" "$CONFIG_FILE")"
  if ! has_value "$value"; then
    value="true"
  fi
  printf '%s' "$value"
}

# ── JSON Schema validation (structure / types / enums) ───────────────────────
# A config declares its contract version with an optional top-level `version`
# field (default 1). Each version has a frozen schema under schemas/v<N>/, so
# evolving the config contract never changes the schema a production v1 config
# validates against. The schema covers shape only; the semantic cross-field
# checks below (and the apply/sync scripts) own everything that needs context
# the schema cannot express.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

schema_name=""
case "$CONFIG_TYPE" in
  budgets) schema_name="budget-policies.schema.json" ;;
  teams) schema_name="cost-center-members.schema.json" ;;
  all) schema_name="copilot-finops.schema.json" ;;
esac

if [[ -n "$schema_name" ]]; then
  schema_version="$(yq eval '.version // 1' "$CONFIG_FILE")"
  if ! [[ "$schema_version" =~ ^[0-9]+$ ]]; then
    echo "ERROR: top-level 'version' must be a whole number (got '$schema_version')" >&2
    exit 1
  fi
  # v2 is the single merged config, validated with type 'all'; v1 uses the split
  # budgets/teams files. Guard the pairing so a mismatch gives a clear message
  # instead of a confusing "no schema for version" error.
  if [[ "$CONFIG_TYPE" == "all" ]] && ((schema_version < 2)); then
    echo "ERROR: config type 'all' is for the merged v2 config (version: 2); got version $schema_version" >&2
    exit 1
  fi
  if [[ "$CONFIG_TYPE" != "all" ]] && ((schema_version >= 2)); then
    echo "ERROR: version $schema_version uses the merged config; validate it with type 'all' (not '$CONFIG_TYPE')" >&2
    exit 1
  fi
  schema_file="$REPO_ROOT/schemas/v$schema_version/$schema_name"
  if [[ ! -f "$schema_file" ]]; then
    echo "ERROR: no schema for config version $schema_version at schemas/v$schema_version/$schema_name" >&2
    supported="$(find "$REPO_ROOT/schemas" -maxdepth 1 -type d -name 'v*' 2>/dev/null | sed 's:.*/v::' | sort -n | tr '\n' ' ')"
    [[ -n "$supported" ]] && echo "HINT: supported versions: $supported" >&2
    exit 1
  fi
  if command -v check-jsonschema >/dev/null 2>&1; then
    if ! check-jsonschema --schemafile "$schema_file" "$CONFIG_FILE"; then
      echo "ERROR: schema validation failed: $CONFIG_FILE (schemas/v$schema_version/$schema_name)" >&2
      exit 1
    fi
  else
    echo "WARN: check-jsonschema not found; skipping JSON Schema validation (structure/type checks)." >&2
    echo "HINT: install it with 'pipx install check-jsonschema' (or 'pip install check-jsonschema') for full validation." >&2
  fi
fi

case "$CONFIG_TYPE" in
  teams)
    if [[ "$(yq eval 'has("mappings")' "$CONFIG_FILE")" != "true" ]]; then
      echo "ERROR: teams config must include top-level key: mappings" >&2
      exit 1
    fi
    if [[ "$(yq eval '.mappings | type' "$CONFIG_FILE")" != "!!seq" ]]; then
      echo "ERROR: teams config .mappings must be a list" >&2
      exit 1
    fi
    # Validate each mapping has required fields
    count="$(yq eval '.mappings | length' "$CONFIG_FILE")"
    for ((i = 0; i < count; i++)); do
      name="$(config_value ".mappings[$i].name")"
      has_value "$name" || name="mapping-$i"
      team_slug="$(config_value ".mappings[$i].source.team_slug")"
      cost_center="$(config_value ".mappings[$i].target.cost_center")"
      source_org="$(config_value ".mappings[$i].source.org")"
      source_ent="$(config_value ".mappings[$i].source.enterprise")"
      if ! has_value "$team_slug"; then
        echo "ERROR: mapping '$name' is missing source.team_slug" >&2
        exit 1
      fi
      if ! has_value "$cost_center"; then
        echo "ERROR: mapping '$name' is missing target.cost_center" >&2
        exit 1
      fi
      if ! has_value "$source_org" && ! has_value "$source_ent"; then
        echo "ERROR: mapping '$name' must have source.org or source.enterprise" >&2
        exit 1
      fi
    done
    ;;
  budgets)
    if [[ "$(yq eval 'has("budget_policies")' "$CONFIG_FILE")" != "true" ]]; then
      echo "ERROR: budget config must include top-level key: budget_policies" >&2
      exit 1
    fi
    if [[ "$(yq eval '.budget_policies | type' "$CONFIG_FILE")" != "!!seq" ]]; then
      echo "ERROR: budget config .budget_policies must be a list" >&2
      exit 1
    fi
    # Validate each policy has required fields
    count="$(yq eval '.budget_policies | length' "$CONFIG_FILE")"
    for ((i = 0; i < count; i++)); do
      name="$(config_value ".budget_policies[$i].name")"
      has_value "$name" || name="policy-$i"
      policy_type="$(config_value ".budget_policies[$i].type")"
      if ! has_value "$policy_type"; then
        echo "ERROR: budget policy '$name' is missing required field: type (enterprise|universal|cost_center|team)" >&2
        exit 1
      fi
      case "$policy_type" in
        enterprise | universal | cost_center | team) ;;
        *)
          echo "ERROR: budget policy '$name' has invalid type '$policy_type'. Valid: enterprise, universal, cost_center, team" >&2
          exit 1
          ;;
      esac

      # GA budgets API: budget_amount is required. budget.product_sku is optional
      # and defaults to ai_credits in the apply scripts when omitted.
      amount="$(config_value ".budget_policies[$i].budget.amount")"
      if ! [[ "$amount" =~ ^[0-9]+$ ]]; then
        echo "ERROR: budget policy '$name' budget.amount must be a non-negative whole number (USD)" >&2
        exit 1
      fi

      # user / multi_user_customer scopes always hard-stop: prevent_further_usage
      # defaults to true and may not be set to false. This applies to `universal`
      # and to `team` policies that materialize as per-member user budgets
      # (coverage: total_spend). A `team` policy with coverage: additional_spend
      # materializes as a cost center budget, where the hard stop is optional
      # (checked below).
      prevent="$(read_default_true ".budget_policies[$i].budget.prevent_further_usage")"
      if [[ "$policy_type" == "universal" ]]; then
        if [[ "$prevent" != "true" ]]; then
          echo "ERROR: budget policy '$name' (type=$policy_type) must not set budget.prevent_further_usage: false (user-level budgets always hard-stop)" >&2
          exit 1
        fi
      fi

      if [[ "$policy_type" == "team" ]]; then
        team_slug="$(config_value ".budget_policies[$i].source.team_slug")"
        source_org="$(config_value ".budget_policies[$i].source.org")"
        source_ent="$(config_value ".budget_policies[$i].source.enterprise")"
        coverage="$(config_value ".budget_policies[$i].coverage")"
        has_value "$coverage" || coverage="total_spend"
        if ! has_value "$team_slug"; then
          echo "ERROR: budget policy '$name' (type=team) is missing source.team_slug" >&2
          exit 1
        fi
        if ! has_value "$source_org" && ! has_value "$source_ent"; then
          echo "ERROR: budget policy '$name' (type=team) must have source.org or source.enterprise" >&2
          exit 1
        fi
        case "$coverage" in
          total_spend)
            # Materialized as per-member user budgets, which always hard-stop.
            if [[ "$prevent" != "true" ]]; then
              echo "ERROR: budget policy '$name' (type=team, coverage=total_spend) must not set budget.prevent_further_usage: false (per-member user budgets always hard-stop)" >&2
              exit 1
            fi
            ;;
          additional_spend)
            # Materialized as one cost center budget. target.cost_center is
            # optional: when omitted the apply step derives a name from the team
            # source and auto-creates the cost center. The hard stop is optional
            # here (cost center budgets may alert-only), so no prevent check.
            :
            ;;
          *)
            echo "ERROR: budget policy '$name' (type=team) has invalid coverage '$coverage'. Valid: total_spend (per-member user budgets), additional_spend (cost center budget)" >&2
            exit 1
            ;;
        esac
      fi

      # cost_center budgets target a single cost center by name (resolved to its
      # ID at apply time) and must include target.cost_center.
      if [[ "$policy_type" == "cost_center" ]]; then
        cost_center="$(config_value ".budget_policies[$i].target.cost_center")"
        if ! has_value "$cost_center"; then
          echo "ERROR: budget policy '$name' (type=cost_center) is missing target.cost_center" >&2
          exit 1
        fi
      fi
    done
    ;;
  all)
    # v2 merged config (config/copilot-finops.yml). The JSON Schema
    # (schemas/v2/copilot-finops.schema.json) already enforces the structural
    # cross-field rules 1-8; these bash re-checks add friendly, billing-aware
    # messages AND keep the rules enforced when check-jsonschema is unavailable.
    # Runtime/live rules stay in the apply/sync scripts: enterprise slug
    # resolution (CLI > per-entry enterprise > top-level enterprise_slug) and
    # live cost center name->ID + team membership lookups. stop_at_limit uses the
    # raw-read default-true pattern (rule D) so an explicit false is preserved.
    # Both lists are optional in v2 (write only what you need). When present each
    # must be a list; an absent list is treated as empty.
    for key in ai_credit_spend_policies team_cost_center_mappings; do
      if [[ "$(yq eval "has(\"$key\")" "$CONFIG_FILE")" == "true" ]] \
        && [[ "$(yq eval ".$key | type" "$CONFIG_FILE")" != "!!seq" ]]; then
        echo "ERROR: v2 config .$key must be a list" >&2
        exit 1
      fi
    done

    # ── ai_credit_spend_policies ────────────────────────────────────────────────
    count="$(yq eval '(.ai_credit_spend_policies // []) | length' "$CONFIG_FILE")"
    for ((i = 0; i < count; i++)); do
      name="$(config_value ".ai_credit_spend_policies[$i].name")"
      has_value "$name" || name="policy-$i"

      scope="$(config_value ".ai_credit_spend_policies[$i].scope")"
      if ! has_value "$scope"; then
        echo "ERROR: spend policy '$name' is missing required field: scope (all_users|enterprise|cost_center|team|organization|user)" >&2
        exit 1
      fi
      case "$scope" in
        all_users | enterprise | cost_center | team | organization | user) ;;
        *)
          echo "ERROR: spend policy '$name' has invalid scope '$scope'. Valid: all_users, enterprise, cost_center, team, organization, user" >&2
          exit 1
          ;;
      esac

      amount="$(config_value ".ai_credit_spend_policies[$i].amount")"
      if ! [[ "$amount" =~ ^[0-9]+$ ]]; then
        echo "ERROR: spend policy '$name' amount must be a non-negative whole number (USD)" >&2
        exit 1
      fi

      # v2 budget policies use plural lists. The singular v2-beta fields are not
      # valid even when check-jsonschema is unavailable.
      for f in user team; do
        if has_key ".ai_credit_spend_policies[$i]" "$f"; then
          echo "ERROR: spend policy '$name' uses unsupported field '$f'; use 'users' for scope=user and 'teams' for scope=team" >&2
          exit 1
        fi
      done

      # Rule 6: enterprise and organization are mutually exclusive on one entry.
      p_enterprise="$(config_value ".ai_credit_spend_policies[$i].enterprise")"
      p_organization="$(config_value ".ai_credit_spend_policies[$i].organization")"
      if has_value "$p_enterprise" && has_value "$p_organization"; then
        echo "ERROR: spend policy '$name' sets both enterprise and organization (mutually exclusive)" >&2
        exit 1
      fi

      # Rule D: default stop_at_limit to true while preserving an explicit false.
      stop_at_limit="$(read_default_true ".ai_credit_spend_policies[$i].stop_at_limit")"

      case "$scope" in
        all_users)
          # Forbids identity / credit_scope / remove_extra_members; hard-stop forced.
          for f in teams cost_center credit_scope organization remove_extra_members users; do
            if has_key ".ai_credit_spend_policies[$i]" "$f"; then
              echo "ERROR: spend policy '$name' (scope=all_users) must not set '$f'" >&2
              exit 1
            fi
          done
          if [[ "$stop_at_limit" != "true" ]]; then
            echo "ERROR: spend policy '$name' (scope=all_users) must not set stop_at_limit: false (per-user budgets always hard-stop)" >&2
            exit 1
          fi
          ;;
        enterprise)
          for f in teams cost_center credit_scope organization remove_extra_members users; do
            if has_key ".ai_credit_spend_policies[$i]" "$f"; then
              echo "ERROR: spend policy '$name' (scope=enterprise) must not set '$f'" >&2
              exit 1
            fi
          done
          ;;
        cost_center)
          # Requires cost_center; forbids the rest.
          cc="$(config_value ".ai_credit_spend_policies[$i].cost_center")"
          if ! has_value "$cc"; then
            echo "ERROR: spend policy '$name' (scope=cost_center) is missing cost_center" >&2
            exit 1
          fi
          for f in teams credit_scope organization remove_extra_members users; do
            if has_key ".ai_credit_spend_policies[$i]" "$f"; then
              echo "ERROR: spend policy '$name' (scope=cost_center) must not set '$f'" >&2
              exit 1
            fi
          done
          ;;
        user)
          # One hard-stop user budget per login in the users list. Requires a
          # non-empty users list; forbids every group/identity field; always
          # hard-stop (user-level budgets cannot alert-only).
          users_len="$(yq eval "(.ai_credit_spend_policies[$i].users // []) | length" "$CONFIG_FILE")"
          if ! [[ "$users_len" =~ ^[0-9]+$ ]] || ((users_len < 1)); then
            echo "ERROR: spend policy '$name' (scope=user) must include a non-empty users list (the GitHub logins to budget)" >&2
            exit 1
          fi
          users_unique_len="$(yq eval "(.ai_credit_spend_policies[$i].users // []) | unique | length" "$CONFIG_FILE")"
          if [[ "$users_unique_len" != "$users_len" ]]; then
            echo "ERROR: spend policy '$name' (scope=user) must not list the same login more than once in users" >&2
            exit 1
          fi
          for f in teams cost_center credit_scope organization remove_extra_members; do
            if has_key ".ai_credit_spend_policies[$i]" "$f"; then
              echo "ERROR: spend policy '$name' (scope=user) must not set '$f'" >&2
              exit 1
            fi
          done
          if [[ "$stop_at_limit" != "true" ]]; then
            echo "ERROR: spend policy '$name' (scope=user) must not set stop_at_limit: false (user-level budgets always hard-stop)" >&2
            exit 1
          fi
          ;;
        team)
          # Requires a non-empty teams list and credit_scope; the policy is
          # applied to each listed team.
          teams_len="$(yq eval "(.ai_credit_spend_policies[$i].teams // []) | length" "$CONFIG_FILE")"
          credit_scope="$(config_value ".ai_credit_spend_policies[$i].credit_scope")"
          if ! [[ "$teams_len" =~ ^[0-9]+$ ]] || ((teams_len < 1)); then
            echo "ERROR: spend policy '$name' (scope=team) must include a non-empty teams list" >&2
            exit 1
          fi
          teams_unique_len="$(yq eval "(.ai_credit_spend_policies[$i].teams // []) | unique | length" "$CONFIG_FILE")"
          if [[ "$teams_unique_len" != "$teams_len" ]]; then
            echo "ERROR: spend policy '$name' (scope=team) must not list the same team more than once in teams" >&2
            exit 1
          fi
          if ! has_value "$credit_scope"; then
            echo "ERROR: spend policy '$name' (scope=team) is missing credit_scope (pool_then_metered|metered_only)" >&2
            exit 1
          fi
          if has_key ".ai_credit_spend_policies[$i]" "users"; then
            echo "ERROR: spend policy '$name' (scope=team) must not set 'users'" >&2
            exit 1
          fi
          case "$credit_scope" in
            pool_then_metered)
              # Materializes as per-member user budgets; no cost center to
              # reconcile, and always hard-stop.
              for f in cost_center remove_extra_members; do
                if has_key ".ai_credit_spend_policies[$i]" "$f"; then
                  echo "ERROR: spend policy '$name' (scope=team, credit_scope=pool_then_metered) must not set '$f'" >&2
                  exit 1
                fi
              done
              if [[ "$stop_at_limit" != "true" ]]; then
                echo "ERROR: spend policy '$name' (scope=team, credit_scope=pool_then_metered) must not set stop_at_limit: false (per-member user budgets always hard-stop)" >&2
                exit 1
              fi
              ;;
            metered_only)
              # Each team fans out to its own derived/auto-created cost center
              # budget. cost_center is an optional explicit destination only when
              # exactly one team is listed; with multiple teams it is ambiguous.
              if ((teams_len > 1)) && has_key ".ai_credit_spend_policies[$i]" "cost_center"; then
                echo "ERROR: spend policy '$name' (scope=team, credit_scope=metered_only) lists multiple teams and must not set 'cost_center' (each team uses its own derived cost center)" >&2
                exit 1
              fi
              ;;
            *)
              echo "ERROR: spend policy '$name' (scope=team) has invalid credit_scope '$credit_scope'. Valid: pool_then_metered, metered_only" >&2
              exit 1
              ;;
          esac
          ;;
        organization)
          # Dual-track like team, but keyed on the organization itself (rule 7:
          # organization is also valid as the org an organization-scope budget
          # belongs to). Requires organization + credit_scope; forbids team,
          # cost_center, and remove_extra_members (org metered_only is a direct
          # org-scope budget, not a cost center).
          org="$(config_value ".ai_credit_spend_policies[$i].organization")"
          credit_scope="$(config_value ".ai_credit_spend_policies[$i].credit_scope")"
          if ! has_value "$org"; then
            echo "ERROR: spend policy '$name' (scope=organization) is missing organization" >&2
            exit 1
          fi
          if ! has_value "$credit_scope"; then
            echo "ERROR: spend policy '$name' (scope=organization) is missing credit_scope (pool_then_metered|metered_only)" >&2
            exit 1
          fi
          for f in teams cost_center remove_extra_members users; do
            if has_key ".ai_credit_spend_policies[$i]" "$f"; then
              echo "ERROR: spend policy '$name' (scope=organization) must not set '$f'" >&2
              exit 1
            fi
          done
          case "$credit_scope" in
            pool_then_metered)
              # Per-member user budgets across the org's members; always hard-stop.
              if [[ "$stop_at_limit" != "true" ]]; then
                echo "ERROR: spend policy '$name' (scope=organization, credit_scope=pool_then_metered) must not set stop_at_limit: false (per-member user budgets always hard-stop)" >&2
                exit 1
              fi
              ;;
            metered_only)
              # One org-scope budget; stop_at_limit optional.
              :
              ;;
            *)
              echo "ERROR: spend policy '$name' (scope=organization) has invalid credit_scope '$credit_scope'. Valid: pool_then_metered, metered_only" >&2
              exit 1
              ;;
          esac
          ;;
      esac
    done

    # Rule 10 (S+V): when ai_credit_spend_policies is non-empty it must contain
    # exactly one all_users default; an enterprise cap is optional but capped at
    # one. An empty/omitted list stays a valid no-op. The v2 schema enforces this
    # too (contains + minContains/maxContains, draft 2020-12); this bash re-check
    # is the friendly, billing-sensitive message and the fallback when
    # check-jsonschema is not installed.
    if ((count > 0)); then
      n_enterprise="$(yq eval '[(.ai_credit_spend_policies // [])[] | select(.scope == "enterprise")] | length' "$CONFIG_FILE")"
      n_all_users="$(yq eval '[(.ai_credit_spend_policies // [])[] | select(.scope == "all_users")] | length' "$CONFIG_FILE")"
      if ((n_enterprise > 1)); then
        echo "ERROR: ai_credit_spend_policies allows at most one 'enterprise' policy (found $n_enterprise)" >&2
        exit 1
      fi
      if [[ "$n_all_users" != "1" ]]; then
        echo "ERROR: ai_credit_spend_policies must include exactly one 'all_users' policy when any budget policy is defined (found $n_all_users)" >&2
        exit 1
      fi
    fi

    # ── team_cost_center_mappings ────────────────────────────────────────────────
    count="$(yq eval '(.team_cost_center_mappings // []) | length' "$CONFIG_FILE")"
    for ((i = 0; i < count; i++)); do
      name="$(config_value ".team_cost_center_mappings[$i].name")"
      has_value "$name" || name="mapping-$i"
      team="$(config_value ".team_cost_center_mappings[$i].team")"
      cost_center="$(config_value ".team_cost_center_mappings[$i].cost_center")"
      m_enterprise="$(config_value ".team_cost_center_mappings[$i].enterprise")"
      m_organization="$(config_value ".team_cost_center_mappings[$i].organization")"
      # Rule 8: a mapping needs team and cost_center.
      if ! has_value "$team"; then
        echo "ERROR: mapping '$name' is missing team" >&2
        exit 1
      fi
      if ! has_value "$cost_center"; then
        echo "ERROR: mapping '$name' is missing cost_center" >&2
        exit 1
      fi
      # Rule 6: enterprise and organization are mutually exclusive on one entry.
      if has_value "$m_enterprise" && has_value "$m_organization"; then
        echo "ERROR: mapping '$name' sets both enterprise and organization (mutually exclusive)" >&2
        exit 1
      fi
    done
    ;;
  *)
    echo "ERROR: Unknown config type '$CONFIG_TYPE'. Use teams, budgets, or all." >&2
    exit 1
    ;;
esac

echo "Config validation passed: $CONFIG_FILE ($CONFIG_TYPE)"
