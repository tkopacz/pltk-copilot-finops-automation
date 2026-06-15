#!/usr/bin/env bash
set -euo pipefail

ENTERPRISE_SLUG=""
ENTERPRISE_SLUG_CLI=""
CONFIG_FILE="config/copilot-finops.example.yml"
POLICY_NAME=""
DRY_RUN="true"

# Latest billing (budgets) REST API version. Override only if you pin a different one.
GH_API_VERSION="${GH_API_VERSION:-2026-03-10}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enterprise-slug)
      ENTERPRISE_SLUG="$2"
      ENTERPRISE_SLUG_CLI="$2"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --policy-name)
      POLICY_NAME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v yq >/dev/null 2>&1; then
  echo "ERROR: gh, jq, and yq are required." >&2
  exit 1
fi

# v2 merges budgets + member mappings into one file and renames the vocab; it is
# validated with type 'all'. v1 keeps the split budgets file. Detect the version
# once and branch the validation + per-policy field reads accordingly.
CONFIG_VERSION="$(yq eval '.version // 1' "$CONFIG_FILE")"

# v2 renamed the budgets list key to ai_credit_spend_policies; v1 keeps
# budget_policies. BLIST is the list key for the active version.
if [[ "$CONFIG_VERSION" == "2" ]]; then
  BLIST="ai_credit_spend_policies"
else
  BLIST="budget_policies"
fi

if [[ "$CONFIG_VERSION" == "2" ]]; then
  scripts/validate-config.sh "$CONFIG_FILE" all >/dev/null
else
  scripts/validate-config.sh "$CONFIG_FILE" budgets >/dev/null
fi

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  ENTERPRISE_SLUG="$(yq eval '.enterprise_slug // ""' "$CONFIG_FILE")"
fi

# v2 allows a per-entry enterprise: as a "no top-level slug" convenience. When no
# CLI / top-level slug is set, fall back to the first per-entry enterprise so the
# budget write and cost center endpoints still resolve (rule 9: one must resolve).
if [[ -z "$ENTERPRISE_SLUG" && "$CONFIG_VERSION" == "2" ]]; then
  ENTERPRISE_SLUG="$(yq eval "[(.${BLIST} // [])[].enterprise] | map(select(. != null and . != \"\")) | .[0] // \"\"" "$CONFIG_FILE")"
fi

if [[ -z "$ENTERPRISE_SLUG" ]]; then
  echo "ERROR: enterprise slug is required via --enterprise-slug, config.enterprise_slug, or a per-entry enterprise:" >&2
  exit 1
fi

# GA budgets endpoint (override only if you proxy the API).
budgets_tpl="$(yq eval '.api.budgets_endpoint_template // "/enterprises/{enterprise}/settings/billing/budgets"' "$CONFIG_FILE")"
budgets_endpoint="${budgets_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"

# Org-level budgets live on the organization billing endpoint (a different
# endpoint than the enterprise one). A scope: organization policy's parent is the
# org, so its budgets — the org-scope budget and the per-member user budgets it
# fans out to — are written here. The org budgets API supports
# organization/repository/multi_user_customer/user scopes (user/multi_user_customer
# only with ai_credits or premium_requests), but NOT cost_center, so cost-center
# budgets always stay on the enterprise endpoint.
org_budgets_tpl="$(yq eval '.api.org_budgets_endpoint_template // "/organizations/{organization}/settings/billing/budgets"' "$CONFIG_FILE")"

# GA cost-centers list endpoint, used to resolve a cost center name to its ID
# (the budgets API references cost centers by ID, not by display name).
cc_list_tpl="$(yq eval '.api.cost_centers_list_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers"' "$CONFIG_FILE")"
cc_list_endpoint="${cc_list_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"

# GA cost-center get-by-id + resource endpoints, used to populate a cost center
# with a team's members for an additional_spend budget (so the cost center the
# budget caps actually contains the people whose metered spend it limits).
cc_get_tpl="$(yq eval '.api.cost_center_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}"' "$CONFIG_FILE")"
cc_resource_tpl="$(yq eval '.api.cost_center_resource_endpoint_template // "/enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource"' "$CONFIG_FILE")"

policy_count="$(yq eval "(.${BLIST} // []) | length" "$CONFIG_FILE")"
if [[ "$policy_count" -eq 0 ]]; then
  echo "No budget policies found in $CONFIG_FILE"
  exit 0
fi

has_value() {
  [[ -n "$1" && "$1" != "null" ]]
}

read_prevent_further_usage() {
  local policy_index="$1" value
  value="$(yq eval ".budget_policies[$policy_index].budget.prevent_further_usage" "$CONFIG_FILE")"
  if ! has_value "$value"; then
    value="true"
  fi
  printf '%s' "$value"
}

derive_budget_type() {
  local sku="$1"
  case "$sku" in
    ai_credits) printf '%s' "BundlePricing" ;;
    *) printf '%s' "ProductPricing" ;;
  esac
}

# Effective enterprise slug for a v2 entry's enterprise-team membership reads:
# CLI --enterprise-slug wins, then the per-entry enterprise:, then the run-level
# slug. Budgets and cost centers always use the run-level ENTERPRISE_SLUG (one
# token = one enterprise); organization: only switches where membership is read.
resolve_entry_enterprise() {
  local entry_ent="$1"
  if [[ -n "$ENTERPRISE_SLUG_CLI" ]]; then
    printf '%s' "$ENTERPRISE_SLUG_CLI"
  elif has_value "$entry_ent"; then
    printf '%s' "$entry_ent"
  else
    printf '%s' "$ENTERPRISE_SLUG"
  fi
}

team_source_label() {
  local source_org="$1" source_enterprise="$2" team_slug="$3"
  if has_value "$source_enterprise"; then
    printf 'enterprise team %s/%s' "$source_enterprise" "$team_slug"
  else
    printf 'org team %s/%s' "$source_org" "$team_slug"
  fi
}

default_team_cost_center_name() {
  local source_org="$1" source_enterprise="$2" team_slug="$3"
  if has_value "$source_enterprise"; then
    printf 'cc-ent-%s-%s' "$source_enterprise" "$team_slug"
  else
    printf 'cc-org-%s-%s' "$source_org" "$team_slug"
  fi
}

# Fetch all members of an org team or enterprise team, returns sorted, unique logins.
# Both org teams (array response) and enterprise teams (object with members[] field) are handled.
fetch_team_logins() {
  local source_org="$1"
  local source_enterprise="$2"
  local team_slug="$3"
  local endpoint

  if has_value "$source_enterprise"; then
    endpoint="/enterprises/$source_enterprise/teams/$team_slug/memberships?per_page=100"
  else
    endpoint="/orgs/$source_org/teams/$team_slug/members?per_page=100"
  fi

  # gh api errors are intentionally left on stderr so callers can detect failures.
  gh api --paginate "$endpoint" | jq -r '
    if type == "array" then .[]
    elif type == "object" and has("members") then .members[]
    else empty end
    | if type == "object" and has("login") then .login
      elif type == "string" then .
      elif type == "object" and has("user") and .user.login then .user.login
      else empty end
  ' | sort -u
}

# List the current User members of a cost center by ID (sorted, unique logins).
# Errors are swallowed so callers can treat a missing/unreadable cost center as
# "no current members" (e.g. a not-yet-created cost center during a dry run).
fetch_cost_center_logins() {
  local cc_id="$1" endpoint
  endpoint="${cc_get_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{cost_center_id\}/$cc_id}"
  gh api --paginate "$endpoint?per_page=100" 2>/dev/null \
    | jq -r '
        (.resources // []) | .[]
        | select((.type // "" | ascii_downcase) == "user")
        | .name
      ' \
    | sort -u
}

# Add user logins to a cost center via the resource endpoint
# (POST .../cost-centers/{id}/resource {"users":[...]}), in batches of up to 50.
# Honors DRY_RUN. Diagnostics go to stderr/stdout; returns non-zero on failure.
add_cost_center_members() {
  local cc_id="$1"
  shift
  local users=("$@")
  [[ ${#users[@]} -eq 0 ]] && return 0

  local endpoint idx end batch_size=50
  endpoint="${cc_resource_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{cost_center_id\}/$cc_id}"

  for ((idx = 0; idx < ${#users[@]}; idx += batch_size)); do
    end=$((idx + batch_size))
    ((end > ${#users[@]})) && end=${#users[@]}
    local slice=("${users[@]:idx:end-idx}")

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "DRY RUN: Would add ${#slice[@]} member(s) to cost center '$cc_id': ${slice[*]}"
      continue
    fi

    local payload
    payload="$(printf '%s\n' "${slice[@]}" | jq -R . | jq -s '{users: .}')"
    if ! gh api -X POST "$endpoint" \
        -H "X-GitHub-Api-Version: $GH_API_VERSION" \
        --input - <<<"$payload" >/dev/null 2>&1; then
      echo "ERROR: Failed to add members to cost center '$cc_id' via '$endpoint'." >&2
      echo "HINT: A 404 means the enhanced billing feature is not enabled or the cost center ID is wrong." >&2
      return 1
    fi
    echo "Added ${#slice[@]} member(s) to cost center '$cc_id': ${slice[*]}"
  done
}

# Remove user logins from a cost center via the resource endpoint
# (DELETE .../cost-centers/{id}/resource {"users":[...]}), in batches of up to 50.
# Honors DRY_RUN. This is apply's own thin removal helper (scripts are standalone,
# no shared lib); it must stay behaviorally identical to the removal path in
# sync-cost-center-members.sh. Used only for v2 team + additional_spend
# budgets with remove_extra_members: true (prune members who left the team).
remove_cost_center_members() {
  local cc_id="$1"
  shift
  local users=("$@")
  [[ ${#users[@]} -eq 0 ]] && return 0

  local endpoint idx end batch_size=50
  endpoint="${cc_resource_tpl//\{enterprise\}/$ENTERPRISE_SLUG}"
  endpoint="${endpoint//\{cost_center_id\}/$cc_id}"

  for ((idx = 0; idx < ${#users[@]}; idx += batch_size)); do
    end=$((idx + batch_size))
    ((end > ${#users[@]})) && end=${#users[@]}
    local slice=("${users[@]:idx:end-idx}")

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "DRY RUN: Would remove ${#slice[@]} member(s) from cost center '$cc_id': ${slice[*]}"
      continue
    fi

    local payload
    payload="$(printf '%s\n' "${slice[@]}" | jq -R . | jq -s '{users: .}')"
    if ! gh api -X DELETE "$endpoint" \
        -H "X-GitHub-Api-Version: $GH_API_VERSION" \
        --input - <<<"$payload" >/dev/null 2>&1; then
      echo "ERROR: Failed to remove members from cost center '$cc_id' via '$endpoint'." >&2
      echo "HINT: A 404 means the enhanced billing feature is not enabled or the cost center ID is wrong." >&2
      return 1
    fi
    echo "Removed ${#slice[@]} member(s) from cost center '$cc_id': ${slice[*]}"
  done
}

# Cache of all existing budgets (a single JSON array), populated once by
# load_live_budgets and queried by find_live_budget during reconciliation.
LIVE_BUDGETS_CACHE=""

# v2 can write budgets to more than one endpoint in a single run: the enterprise
# billing endpoint (default parent) and, for scope: organization, the org billing
# endpoint. Each endpoint has its own budget list, so caches are keyed by
# endpoint. ACTIVE_BUDGETS_ENDPOINT / ACTIVE_BUDGETS_CACHE select which endpoint
# the current policy reconciles against (empty => the enterprise default).
declare -A BUDGET_CACHE_BY_EP=()
declare -A MEMBER_FILE_BY_KEY=()
declare -A CONFLICT_SKIP=()
BUDGET_CACHE_TMPFILES=()
ACTIVE_BUDGETS_ENDPOINT=""
ACTIVE_BUDGETS_CACHE=""
CONFLICTS_DETECTED=0

# Optional structured result sink for rich job summaries. When BUDGET_SUMMARY_FILE
# is set, each reconciled entity appends one JSON record (JSON Lines) describing
# the entity (enterprise / cost center / user) and the action taken. When the
# variable is unset the script behaves exactly as before (portable for local use).
SUMMARY_POLICY=""
SUMMARY_TYPE=""
SUMMARY_SKU=""
SUMMARY_GROUP=""

record_result() {
  [[ -n "${BUDGET_SUMMARY_FILE:-}" ]] || return 0
  local scope="$1" entity_key="$2" action="$3" old_amount="${4:-null}" new_amount="${5:-null}"
  local entity_type entity dry_json
  case "$scope" in
    enterprise)          entity_type="enterprise";  entity="$ENTERPRISE_SLUG" ;;
    multi_user_customer) entity_type="all_users";   entity="all licensed users" ;;
    cost_center)         entity_type="cost_center"; entity="$entity_key" ;;
    user)                entity_type="user";        entity="$entity_key" ;;
    *)                   entity_type="$scope";      entity="$entity_key" ;;
  esac
  [[ "$DRY_RUN" == "true" ]] && dry_json="true" || dry_json="false"
  jq -nc \
    --arg policy "$SUMMARY_POLICY" \
    --arg type "$SUMMARY_TYPE" \
    --arg sku "$SUMMARY_SKU" \
    --arg entity_type "$entity_type" \
    --arg entity "$entity" \
    --arg group "$SUMMARY_GROUP" \
    --arg action "$action" \
    --argjson old_amount "$old_amount" \
    --argjson new_amount "$new_amount" \
    --argjson dry_run "$dry_json" '
      {policy:$policy, type:$type, sku:$sku, entity_type:$entity_type, entity:$entity,
       group:(if $group == "" then null else $group end),
       action:$action, old_amount:$old_amount, new_amount:$new_amount, dry_run:$dry_run}
    ' >>"$BUDGET_SUMMARY_FILE"
}

# Fetch every existing budget into LIVE_BUDGETS_CACHE as one JSON array.
# The list endpoint paginates (max 10 per page) but DOES send Link headers, so
# --paginate is followed; each page's {budgets:[...]} object is then merged.
load_live_budgets() {
  local raw
  if raw="$(gh api --paginate "$budgets_endpoint?per_page=10" \
    -H "X-GitHub-Api-Version: $GH_API_VERSION" 2>/dev/null \
    | jq -s 'map(.budgets // []) | add')"; then
    printf '%s' "$raw" >"$LIVE_BUDGETS_CACHE"
    echo "Loaded $(jq 'length' "$LIVE_BUDGETS_CACHE") existing budget(s) for reconciliation."
  else
    echo "[]" >"$LIVE_BUDGETS_CACHE"
    echo "WARN: Could not list existing budgets; reconciliation degraded (will attempt creates only)." >&2
    echo "HINT: A 404 means enhanced billing is not enabled; check the token has enterprise billing access." >&2
  fi
}

# Build the org billing endpoint for an org login.
org_budgets_endpoint() {
  printf '%s' "${org_budgets_tpl//\{organization\}/$1}"
}

# Lazily load (and memoize) the budget list for an endpoint into a cache file,
# keyed by endpoint. Runs as a statement (not a command substitution) so the
# "Loaded N" line flows to the run log. The path is stored in BUDGET_CACHE_BY_EP.
load_budget_cache_if_needed() {
  local ep="$1" f raw
  [[ -n "${BUDGET_CACHE_BY_EP[$ep]:-}" ]] && return 0
  f="$(mktemp)"
  BUDGET_CACHE_TMPFILES+=("$f")
  if raw="$(gh api --paginate "$ep?per_page=10" \
    -H "X-GitHub-Api-Version: $GH_API_VERSION" 2>/dev/null \
    | jq -s 'map(.budgets // []) | add')"; then
    printf '%s' "$raw" >"$f"
    echo "Loaded $(jq 'length' "$f") existing budget(s) for reconciliation from $ep"
  else
    echo "[]" >"$f"
    echo "WARN: Could not list existing budgets from '$ep'; reconciliation degraded (creates only)." >&2
  fi
  BUDGET_CACHE_BY_EP[$ep]="$f"
}

# Fetch all members of an organization, returns sorted, unique logins.
fetch_org_logins() {
  local org="$1"
  gh api --paginate "/orgs/$org/members?per_page=100" \
    | jq -r 'if type == "array" then .[] else empty end | .login // empty' \
    | sort -u
}

# Fetch (and memoize) the sorted, unique logins for a membership source into a
# tmp file. kind=team uses fetch_team_logins; kind=org reads the org members
# endpoint. The first arg is the output variable name, intentionally avoiding
# command substitution so memoization and cleanup bookkeeping happen in this shell.
member_logins_file() {
  local __out_var="$1" kind="$2" a="$3" b="$4" c="${5:-}" key f
  key="$kind|$a|$b|$c"
  if [[ -n "${MEMBER_FILE_BY_KEY[$key]:-}" ]]; then
    printf -v "$__out_var" '%s' "${MEMBER_FILE_BY_KEY[$key]}"
    return 0
  fi
  f="$(mktemp)"
  BUDGET_CACHE_TMPFILES+=("$f")
  if ! case "$kind" in
    team) fetch_team_logins "$a" "$b" "$c" >"$f" ;;
    org)  fetch_org_logins "$a" >"$f" ;;
    *)    return 2 ;;
  esac; then
    : >"$f"
    printf -v "$__out_var" '%s' "$f"
    return 1
  fi
  MEMBER_FILE_BY_KEY[$key]="$f"
  printf -v "$__out_var" '%s' "$f"
}

# Append one conflict record (JSON Lines) to the budget summary, rendered as a
# dedicated "Conflicts" section. kind: duplicate_user_budget (hard — same login
# gets an individual user budget from 2+ policies; last applied wins) or
# user_cost_center_overlap (informational — a user budget + a cost-center budget
# cover the same login; GHE allows both). No-op when BUDGET_SUMMARY_FILE is unset.
record_conflict() {
  [[ -n "${BUDGET_SUMMARY_FILE:-}" ]] || return 0
  local kind="$1" entity="$2" winner="$3" policies_json="$4" dry_json
  [[ "$DRY_RUN" == "true" ]] && dry_json="true" || dry_json="false"
  jq -nc \
    --arg kind "$kind" --arg entity "$entity" --arg winner "$winner" \
    --argjson policies "$policies_json" --argjson dry_run "$dry_json" '
      {record:"conflict", kind:$kind, entity:$entity,
       winner:(if $winner == "" then null else $winner end),
       policies:$policies, dry_run:$dry_run}
    ' >>"$BUDGET_SUMMARY_FILE"
}

# True when policy index $1 must NOT write the individual user budget for login
# $2 (a later policy is the conflict winner for that login).
conflict_should_skip() {
  [[ -n "${CONFLICT_SKIP["$1|$2"]:-}" ]]
}

# Pre-flight conflict detection. GHE forbids duplicate budgets for the same
# entity, so a login individually budgeted by 2+ policies is a conflict: the last
# policy in config order wins, earlier ones are skipped, and every collision is
# flagged in the summary. Also flags (informational) a login covered by both an
# individual user budget and a cost-center (additional) budget. Read-only; runs
# in dry-run too so previews show conflicts.
detect_conflicts() {
  local -A user_owners=() cc_owners=()
  local -a names_by_idx=()
  local j scope credit_scope name p_org p_ent a b ts logins_file team_logins_file union_file produces login read_failures=0
  for ((j = 0; j < policy_count; j++)); do
    name="$(yq eval ".${BLIST}[$j].name // \"policy-$j\"" "$CONFIG_FILE")"
    names_by_idx[j]="$name"
    [[ -n "$POLICY_NAME" && "$name" != "$POLICY_NAME" ]] && continue
    scope="$(yq eval ".${BLIST}[$j].scope // \"\"" "$CONFIG_FILE")"
    # v2 surface field is credit_scope (pool_then_metered/metered_only); only
    # scope: team/organization carry it, and detect_conflicts is v2-only in
    # practice (v1 has no .scope, so the loop below skips v1 policies).
    credit_scope="$(yq eval ".${BLIST}[$j].credit_scope // \"\"" "$CONFIG_FILE")"
    p_org="$(yq eval ".${BLIST}[$j].organization // \"\"" "$CONFIG_FILE")"
    p_ent="$(yq eval ".${BLIST}[$j].enterprise // \"\"" "$CONFIG_FILE")"
    logins_file=""
    produces=""
    if [[ "$scope" == "team" ]]; then
      if has_value "$p_org"; then a="$p_org"; b=""; else a=""; b="$(resolve_entry_enterprise "$p_ent")"; fi
      # Union the members of every team this policy lists (deduped) so a login in
      # two of the policy's teams is registered once.
      union_file="$(mktemp)"
      BUDGET_CACHE_TMPFILES+=("$union_file")
      while IFS= read -r ts; do
        [[ -n "$ts" ]] || continue
        if member_logins_file team_logins_file team "$a" "$b" "$ts"; then
          cat "$team_logins_file" >>"$union_file"
        else
          echo "ERROR: Failed to read members for team '$ts' during conflict pre-flight for policy '$name'." >&2
          read_failures=$((read_failures + 1))
        fi
      done < <(yq eval ".${BLIST}[$j].teams[]?" "$CONFIG_FILE")
      sort -u "$union_file" -o "$union_file"
      logins_file="$union_file"
      [[ "$credit_scope" == "pool_then_metered" ]] && produces="user" || produces="cc"
    elif [[ "$scope" == "organization" ]]; then
      if ! member_logins_file logins_file org "$p_org" "" ""; then
        echo "ERROR: Failed to read organization members during conflict pre-flight for policy '$name' (organization '$p_org')." >&2
        read_failures=$((read_failures + 1))
        continue
      fi
      [[ "$credit_scope" == "pool_then_metered" ]] && produces="user" || produces="org"
    elif [[ "$scope" == "user" ]]; then
      # Each listed login owns its own user budget; register each directly so it
      # collides with any team/org pool_then_metered policy on the same login.
      while IFS= read -r login; do
        [[ -n "$login" ]] && user_owners[$login]="${user_owners[$login]:-}$j "
      done < <(yq eval ".${BLIST}[$j].users[]?" "$CONFIG_FILE")
      continue
    else
      continue
    fi
    [[ -s "$logins_file" ]] || continue
    if [[ "$produces" == "user" ]]; then
      while IFS= read -r login; do
        [[ -n "$login" ]] && user_owners[$login]="${user_owners[$login]:-}$j "
      done <"$logins_file"
    elif [[ "$produces" == "cc" ]]; then
      while IFS= read -r login; do
        [[ -n "$login" ]] && cc_owners[$login]="${cc_owners[$login]:-}$name;"
      done <"$logins_file"
    fi
  done

  local owners last o names_json
  for login in "${!user_owners[@]}"; do
    read -ra owners <<<"${user_owners[$login]}"
    ((${#owners[@]} > 1)) || continue
    last="${owners[-1]}"
    for o in "${owners[@]}"; do
      [[ "$o" == "$last" ]] || CONFLICT_SKIP["$o|$login"]=1
    done
    names_json="$(for o in "${owners[@]}"; do printf '%s\n' "${names_by_idx[$o]}"; done | jq -R '.' | jq -s '.')"
    record_conflict "duplicate_user_budget" "$login" "${names_by_idx[$last]}" "$names_json"
    CONFLICTS_DETECTED=$((CONFLICTS_DETECTED + 1))
    echo "CONFLICT: user '$login' is individually budgeted by ${#owners[@]} policies; last applied wins: '${names_by_idx[$last]}' (others skipped)." >&2
  done

  for login in "${!cc_owners[@]}"; do
    [[ -n "${user_owners[$login]:-}" ]] || continue
    names_json="$(printf '%s' "${cc_owners[$login]%;}" | tr ';' '\n' | jq -R '.' | jq -s '.')"
    record_conflict "user_cost_center_overlap" "$login" "" "$names_json"
    echo "NOTE: user '$login' has an individual user budget and is also in a cost-center budget (both allowed; informational)." >&2
  done

  ((read_failures == 0))
}

# Resolve a cost center name to its GA string ID (empty if not found). Deleted
# cost centers are skipped. The budgets API references cost centers by this ID.
resolve_cost_center_id() {
  local name="$1"
  gh api --paginate "$cc_list_endpoint" 2>/dev/null \
    | jq -r --arg n "$name" '
        (.costCenters // []) | .[]
        | select((.state // "active") != "deleted")
        | select(.name == $n) | .id
      ' \
    | head -n1
}

# Resolve a cost center name to its ID, CREATING the cost center when none
# exists yet (POST .../cost-centers, body {"name": ...}). This lets a team's
# additional_spend budget provision its own cost center instead of failing when
# no mapping exists. Honors DRY_RUN (prints intent, echoes a placeholder ID).
# The ID is written to stdout; all diagnostics go to stderr so the surrounding
# command substitution captures only the ID. Returns non-zero on create failure.
ensure_cost_center_id() {
  local name="$1" id created
  id="$(resolve_cost_center_id "$name")"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return 0
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would CREATE cost center '$name' (no existing cost center for this team)" >&2
    printf '%s' "<new-cost-center-id>"
    return 0
  fi
  if ! created="$(gh api -X POST "$cc_list_endpoint" \
      -H "X-GitHub-Api-Version: $GH_API_VERSION" \
      --input - <<<"$(jq -nc --arg name "$name" '{name: $name}')" 2>/dev/null)"; then
    echo "ERROR: Failed to create cost center '$name' via POST '$cc_list_endpoint'." >&2
    echo "HINT: A 409 conflict means the name is already taken (possibly by a deleted cost center); choose a different target.cost_center." >&2
    return 1
  fi
  id="$(printf '%s' "$created" | jq -r '.id // empty')"
  # Fall back to a re-resolve in case the create response shape differs.
  [[ -z "$id" ]] && id="$(resolve_cost_center_id "$name")"
  if [[ -z "$id" ]]; then
    echo "ERROR: Created cost center '$name' but could not determine its ID." >&2
    return 1
  fi
  echo "Created cost center: $name (id=$id)" >&2
  printf '%s' "$id"
}

# Find an existing budget by its natural identity key. Echoes the matching
# budget JSON object, or nothing when there is no match.
# Args: scope sku match_field match_value [match_value2]
#   match_field: "user"   -> match .user (per-member budgets)
#                "entity" -> match .budget_entity_name (e.g. cost center). The
#                            optional match_value2 lets a cost center match by
#                            either its ID or its name (the API takes the ID on
#                            create but may echo the name on read).
#                "none"   -> scope + sku is unique (enterprise, universal)
find_live_budget() {
  local scope="$1" sku="$2" match_field="$3" match_value="$4" match_value2="${5:-}"
  jq -c \
    --arg scope "$scope" \
    --arg sku "$sku" \
    --arg mf "$match_field" \
    --arg mv "$match_value" \
    --arg mv2 "$match_value2" '
      [ .[]
        | select(.budget_scope == $scope)
        | select((.budget_product_sku == $sku)
                 or (((.budget_product_skus // []) | index($sku)) != null))
        | select(
            if $mf == "user" then (.user == $mv)
            elif $mf == "entity" then (.budget_entity_name == $mv
                                       or ($mv2 != "" and .budget_entity_name == $mv2))
            else true end)
      ] | (.[0] // empty)
    ' "${ACTIVE_BUDGETS_CACHE:-$LIVE_BUDGETS_CACHE}"
}

# Return 0 when the live budget already matches the desired mutable fields
# (amount, prevent_further_usage, alerting), 1 when it differs (needs PATCH).
budget_is_current() {
  local live="$1" amount="$2" prevent="$3" will_alert="$4" recipients_json="$5"
  local same
  same="$(jq -n \
    --argjson live "$live" \
    --argjson amount "$amount" \
    --argjson prevent "$prevent" \
    --argjson will_alert "$will_alert" \
    --argjson recipients "$recipients_json" '
      ($live.budget_amount == $amount)
      and ($live.prevent_further_usage == $prevent)
      and (($live.budget_alerting.will_alert // false) == $will_alert)
      and ((($live.budget_alerting.alert_recipients // []) | sort) == ($recipients | sort))
    ')"
  [[ "$same" == "true" ]]
}

# Reconcile one budget so live state matches desired config: create it if it
# does not exist, PATCH it if mutable fields differ, or skip if already current.
# Args: label scope sku match_field match_value amount prevent will_alert recipients_json create_payload [match_value2]
upsert_budget() {
  local label="$1" scope="$2" sku="$3" match_field="$4" match_value="$5"
  local amount="$6" prevent="$7" will_alert="$8" recipients_json="$9" create_payload="${10}" match_value2="${11:-}"
  local ep="${ACTIVE_BUDGETS_ENDPOINT:-$budgets_endpoint}"

  local live
  live="$(find_live_budget "$scope" "$sku" "$match_field" "$match_value" "$match_value2")"

  # No existing budget for this identity -> CREATE.
  if [[ -z "$live" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "DRY RUN: Would CREATE budget $label: $(echo "$create_payload" | jq -c '.')"
      record_result "$scope" "$match_value" "create" "null" "$amount"
      return 0
    fi
    if ! gh api -X POST "$ep" \
      -H "X-GitHub-Api-Version: $GH_API_VERSION" \
      --input - <<<"$create_payload" >/dev/null; then
      echo "ERROR: Failed to create budget $label via '$ep'" >&2
      echo "HINT: A 404 means the enhanced billing feature is not enabled; 422 means the payload was rejected (check scope/SKU/amount)." >&2
      record_result "$scope" "$match_value" "create-failed" "null" "$amount"
      return 1
    fi
    echo "Created budget: $label"
    record_result "$scope" "$match_value" "create" "null" "$amount"
    return 0
  fi

  local budget_id old_amount
  budget_id="$(echo "$live" | jq -r '.id')"
  old_amount="$(echo "$live" | jq -r '.budget_amount // "null"')"

  # Existing budget already matches desired state -> NO-OP.
  if budget_is_current "$live" "$amount" "$prevent" "$will_alert" "$recipients_json"; then
    echo "No change: $label (budget $budget_id already up to date)"
    record_result "$scope" "$match_value" "nochange" "$old_amount" "$amount"
    return 0
  fi

  # Existing budget differs -> UPDATE the mutable fields via PATCH. Identity
  # fields (scope, sku, entity, user) are immutable and are not sent.
  local patch_payload
  patch_payload="$(jq -n \
    --argjson amount "$amount" \
    --argjson prevent "$prevent" \
    --argjson will_alert "$will_alert" \
    --argjson recipients "$recipients_json" '
      {
        budget_amount: $amount,
        prevent_further_usage: $prevent,
        budget_alerting: { will_alert: $will_alert, alert_recipients: $recipients }
      }')"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would UPDATE budget $label (id=$budget_id): $(echo "$patch_payload" | jq -c '.')"
    record_result "$scope" "$match_value" "update" "$old_amount" "$amount"
    return 0
  fi
  if ! gh api -X PATCH "$ep/$budget_id" \
    -H "X-GitHub-Api-Version: $GH_API_VERSION" \
    --input - <<<"$patch_payload" >/dev/null; then
    echo "ERROR: Failed to update budget $label (id=$budget_id) via '$ep/$budget_id'" >&2
    echo "HINT: 422 means the payload was rejected (user/multi_user_customer budgets must keep prevent_further_usage=true)." >&2
    record_result "$scope" "$match_value" "update-failed" "$old_amount" "$amount"
    return 1
  fi
  echo "Updated budget: $label (id=$budget_id)"
  record_result "$scope" "$match_value" "update" "$old_amount" "$amount"
}

# Build a GA budget request body.
# Args: scope amount prevent sku type will_alert recipients_json [user] [entity_name]
# For the `user` scope, the target login is sent in a dedicated `user` field
# (see the GA "add user-level budget" example); other scopes leave it empty.
# For non-user/enterprise scopes (e.g. cost_center), the target entity is named
# via the `budget_entity_name` field.
build_budget_payload() {
  local scope="$1"
  local amount="$2"
  local prevent="$3"
  local sku="$4"
  local btype="$5"
  local will_alert="$6"
  local recipients_json="$7"
  local user="${8:-}"
  local entity_name="${9:-}"

  jq -n \
    --arg scope "$scope" \
    --argjson amount "$amount" \
    --argjson prevent "$prevent" \
    --arg sku "$sku" \
    --arg btype "$btype" \
    --argjson will_alert "$will_alert" \
    --argjson recipients "$recipients_json" \
    --arg user "$user" \
    --arg entity_name "$entity_name" \
    '{
       budget_scope: $scope,
       budget_amount: $amount,
       prevent_further_usage: $prevent,
       budget_product_sku: $sku,
       budget_type: $btype,
       budget_alerting: { will_alert: $will_alert, alert_recipients: $recipients }
     }
     | if $user != "" then . + { user: $user } else . end
     | if $entity_name != "" then . + { budget_entity_name: $entity_name } else . end'
}

failures=0
echo "Applying budget policies for enterprise '$ENTERPRISE_SLUG' (dry_run=$DRY_RUN)"
echo "Budgets endpoint: $budgets_endpoint"
echo "API version: $GH_API_VERSION"

# Reconcile against existing budgets: load them once, then upsert (create/update)
# by each budget's natural identity key instead of blindly creating duplicates.
LIVE_BUDGETS_CACHE="$(mktemp)"
cleanup_tmp() { rm -f "$LIVE_BUDGETS_CACHE" ${BUDGET_CACHE_TMPFILES[@]+"${BUDGET_CACHE_TMPFILES[@]}"}; }
trap cleanup_tmp EXIT
load_live_budgets
# Register the enterprise endpoint's cache in the per-endpoint map, then run the
# read-only conflict pre-flight (memoizes memberships the apply loop reuses).
BUDGET_CACHE_BY_EP["$budgets_endpoint"]="$LIVE_BUDGETS_CACHE"
if ! detect_conflicts; then
  echo "ERROR: conflict pre-flight could not read one or more membership sources; aborting to avoid incomplete duplicate-budget detection." >&2
  exit 1
fi

for ((i = 0; i < policy_count; i++)); do
  if [[ "$CONFIG_VERSION" == "2" ]]; then
    # v2 vocab: scope/coverage/team/organization/cost_center/amount/stop_at_limit/alert_admins.
    name="$(yq eval ".${BLIST}[$i].name // \"policy-$i\"" "$CONFIG_FILE")"
    [[ -n "$POLICY_NAME" && "$name" != "$POLICY_NAME" ]] && continue
    policy_type="$(yq eval ".${BLIST}[$i].scope // \"\"" "$CONFIG_FILE")"
    description="$(yq eval ".${BLIST}[$i].description // \"\"" "$CONFIG_FILE")"
    # v2 has no product SKU / budget type surface; everything is ai_credits.
    sku="ai_credits"
    btype="$(derive_budget_type "$sku")"
    amount="$(yq eval ".${BLIST}[$i].amount // 0" "$CONFIG_FILE")"
    # stop_at_limit -> prevent_further_usage (raw-read default-true: keep explicit false).
    prevent="$(yq eval ".${BLIST}[$i].stop_at_limit" "$CONFIG_FILE")"
    has_value "$prevent" || prevent="true"
    # alert_admins: a non-empty list both enables alerting and is the recipient list.
    recipients_json="$(yq eval -o=json ".${BLIST}[$i].alert_admins // []" "$CONFIG_FILE" | jq -c '.')"
    will_alert="$(jq 'if length > 0 then true else false end' <<<"$recipients_json")"
    # Team source / coverage / destination. organization: => org team; otherwise
    # an enterprise team using the effective enterprise slug.
    p_org="$(yq eval ".${BLIST}[$i].organization // \"\"" "$CONFIG_FILE")"
    p_entry_ent="$(yq eval ".${BLIST}[$i].enterprise // \"\"" "$CONFIG_FILE")"
    mapfile -t teams_list < <(yq eval ".${BLIST}[$i].teams[]?" "$CONFIG_FILE")
    policy_cost_center="$(yq eval ".${BLIST}[$i].cost_center // \"\"" "$CONFIG_FILE")"
    mapfile -t users_list < <(yq eval ".${BLIST}[$i].users[]?" "$CONFIG_FILE")
    remove_extra="$(yq eval ".${BLIST}[$i].remove_extra_members // false" "$CONFIG_FILE")"
    # v2 surface field is credit_scope (pool_then_metered/metered_only); map it to
    # the engine's internal coverage vocab (total_spend/additional_spend), which
    # the dispatch below and v1 both use.
    case "$(yq eval ".${BLIST}[$i].credit_scope // \"\"" "$CONFIG_FILE")" in
      pool_then_metered) coverage="total_spend" ;;
      metered_only) coverage="additional_spend" ;;
      *) coverage="total_spend" ;;
    esac
    if has_value "$p_org"; then
      source_org="$p_org"
      source_enterprise=""
    else
      source_org=""
      source_enterprise="$(resolve_entry_enterprise "$p_entry_ent")"
    fi
    label="scope"
  else
    # v1 vocab: type/coverage/source/target/budget.*.
    name="$(yq eval ".budget_policies[$i].name // \"policy-$i\"" "$CONFIG_FILE")"
    [[ -n "$POLICY_NAME" && "$name" != "$POLICY_NAME" ]] && continue
    policy_type="$(yq eval ".budget_policies[$i].type // \"\"" "$CONFIG_FILE")"
    description="$(yq eval ".budget_policies[$i].description // \"\"" "$CONFIG_FILE")"
    sku="$(yq eval ".budget_policies[$i].budget.product_sku // \"ai_credits\"" "$CONFIG_FILE")"
    amount="$(yq eval ".budget_policies[$i].budget.amount // 0" "$CONFIG_FILE")"
    prevent="$(read_prevent_further_usage "$i")"
    # budget_type follows the SKU. Explicit budget.type still wins for rare cases.
    btype="$(yq eval ".budget_policies[$i].budget.type // \"\"" "$CONFIG_FILE")"
    has_value "$btype" || btype="$(derive_budget_type "$sku")"
    will_alert="$(yq eval ".budget_policies[$i].budget.alerting.will_alert // false" "$CONFIG_FILE")"
    recipients_json="$(yq eval -o=json ".budget_policies[$i].budget.alerting.alert_recipients // []" "$CONFIG_FILE" | jq -c '.')"
    source_org="$(yq eval ".budget_policies[$i].source.org // \"\"" "$CONFIG_FILE")"
    source_enterprise="$(yq eval ".budget_policies[$i].source.enterprise // \"\"" "$CONFIG_FILE")"
    team_slug="$(yq eval ".budget_policies[$i].source.team_slug // \"\"" "$CONFIG_FILE")"
    coverage="$(yq eval ".budget_policies[$i].coverage // \"total_spend\"" "$CONFIG_FILE")"
    policy_cost_center="$(yq eval ".budget_policies[$i].target.cost_center // \"\"" "$CONFIG_FILE")"
    # v1 has no standalone user-scope policy; only v2 carries users.
    users_list=()
    # v1 carries a single team slug; normalize to a one-element teams list (empty
    # for non-team policies) so the team dispatch can iterate uniformly.
    teams_list=()
    has_value "$team_slug" && teams_list=("$team_slug")
    # v1 budgets populate cost centers additively only; ongoing removals live in sync.
    remove_extra="false"
    label="type"
  fi

  # Per-policy context for the structured result records (see record_result).
  SUMMARY_POLICY="$name"
  SUMMARY_TYPE="$policy_type"
  SUMMARY_SKU="$sku"
  SUMMARY_GROUP=""

  echo "---"
  echo "Policy: $name  [$label=$policy_type]"
  has_value "$description" && echo "Description: $description"
  echo "Budget: sku=$sku, amount=$amount, prevent_further_usage=$prevent, type=$btype"

  case "$policy_type" in

    enterprise)
      payload="$(build_budget_payload "enterprise" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json")"
      if ! upsert_budget "$name" "enterprise" "$sku" "none" "" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload"; then
        failures=$((failures + 1))
      fi
      ;;

    all_users | universal)
      payload="$(build_budget_payload "multi_user_customer" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json")"
      if ! upsert_budget "$name" "multi_user_customer" "$sku" "none" "" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload"; then
        failures=$((failures + 1))
      fi
      ;;

    user)
      # One budget per login in the users list (v2 scope: user). Always hard-stop,
      # written on the enterprise endpoint (default parent). Each login also takes
      # part in conflict detection, so if a later team/org pool_then_metered
      # policy budgets the same login, that login is skipped here (last wins).
      if [[ ${#users_list[@]} -eq 0 ]]; then
        echo "ERROR: policy '$name' (user) must include at least one user (the GitHub login(s) to budget)" >&2
        failures=$((failures + 1))
        continue
      fi
      echo "Target users: ${users_list[*]} (per-login user budgets, always hard-stop)"
      for policy_user in "${users_list[@]}"; do
        if conflict_should_skip "$i" "$policy_user"; then
          echo "Skip user '$policy_user' for policy '$name' (budget conflict: a later policy wins this user; see Conflicts in the summary)."
          continue
        fi
        payload="$(build_budget_payload "user" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json" "$policy_user")"
        if ! upsert_budget "$name ($policy_user)" "user" "$sku" "user" "$policy_user" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload"; then
          failures=$((failures + 1))
        fi
      done
      ;;

    cost_center)
      cost_center="$policy_cost_center"
      if ! has_value "$cost_center"; then
        echo "ERROR: policy '$name' (cost_center) must include a cost center" >&2
        failures=$((failures + 1))
        continue
      fi
      # The budgets API identifies a cost center by its GA string ID, not its
      # display name. Resolve the name -> ID for both the create payload and the
      # reconciliation match (a 404 here otherwise means "cost center not found").
      cc_id="$(resolve_cost_center_id "$cost_center")"
      if [[ -z "$cc_id" ]]; then
        echo "ERROR: policy '$name' (type=cost_center): cost center '$cost_center' not found (or is deleted) for enterprise '$ENTERPRISE_SLUG'." >&2
        echo "HINT: Names are matched exactly against '$cc_list_endpoint'." >&2
        failures=$((failures + 1))
        continue
      fi
      echo "Target cost center: $cost_center (id=$cc_id)"
      payload="$(build_budget_payload "cost_center" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json" "" "$cc_id")"
      if ! upsert_budget "$name" "cost_center" "$sku" "entity" "$cost_center" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload" "$cc_id"; then
        failures=$((failures + 1))
      fi
      ;;

    team)
      # Source (source_org / source_enterprise) and coverage are already
      # normalized from the v1/v2 vocab above; teams_list holds one or more team
      # slugs (v1 always exactly one). The policy is applied to each listed team.
      if [[ ${#teams_list[@]} -eq 0 ]]; then
        echo "ERROR: policy '$name' (team) must include at least one team" >&2
        failures=$((failures + 1))
        continue
      fi
      if ! has_value "$source_org" && ! has_value "$source_enterprise"; then
        echo "ERROR: policy '$name' (team) must resolve an org (organization) or enterprise source" >&2
        failures=$((failures + 1))
        continue
      fi

      # ── additional_spend — one cost center budget ───────────────────────────
      # Additional (overspend) is a group-level concern, so the team's collective
      # metered spend is capped by a single cost center budget rather than N
      # per-member budgets. The cost center is provisioned (auto-created when no
      # cost center is given) AND populated with the team's current members, so
      # the budget actually caps the people it is meant to cover. When
      # remove_extra is true (v2 only), members no longer on the team are pruned.
      if [[ "$coverage" == "additional_spend" ]]; then
        for team_slug in "${teams_list[@]}"; do
        echo "Source: $(team_source_label "$source_org" "$source_enterprise" "$team_slug")"
        cost_center="$policy_cost_center"
        if [[ ${#teams_list[@]} -gt 1 ]] || ! has_value "$cost_center"; then
          cost_center="$(default_team_cost_center_name "$source_org" "$source_enterprise" "$team_slug")"
          echo "Using derived cost center '$cost_center' (auto-create if missing)."
        fi
        # Resolve the cost center, creating it when no cost center exists yet.
        if ! cc_id="$(ensure_cost_center_id "$cost_center")"; then
          failures=$((failures + 1))
          continue
        fi
        echo "Coverage: additional spend (metered) -> cost center budget on '$cost_center' (id=$cc_id)"

        SUMMARY_GROUP="$team_slug"
        members_tmp="$(mktemp)"
        if ! fetch_team_logins "$source_org" "$source_enterprise" "$team_slug" >"$members_tmp"; then
          echo "ERROR: Failed to fetch members for team '$team_slug' in policy '$name'" >&2
          echo "HINT: Check that the token has org/enterprise read permissions and the team slug is correct." >&2
          rm -f "$members_tmp"
          failures=$((failures + 1))
          continue
        fi
        mapfile -t team_logins <"$members_tmp"
        echo "Team members found: ${#team_logins[@]}"
        if [[ ${#team_logins[@]} -eq 0 ]]; then
          echo "WARN: team '$team_slug' has no members; cost center '$cost_center' membership left unchanged."
        else
          # Diff the team against the cost center once, then add missing members
          # and (when remove_extra is set) prune members who left the team.
          cc_members_tmp="$(mktemp)"
          fetch_cost_center_logins "$cc_id" >"$cc_members_tmp" || true
          mapfile -t to_add < <(comm -23 "$members_tmp" "$cc_members_tmp")
          mapfile -t to_remove < <(comm -13 "$members_tmp" "$cc_members_tmp")
          rm -f "$cc_members_tmp"
          if [[ ${#to_add[@]} -eq 0 ]]; then
            echo "Cost center '$cost_center' already contains all ${#team_logins[@]} team member(s); no additions."
          elif ! add_cost_center_members "$cc_id" "${to_add[@]}"; then
            failures=$((failures + 1))
          fi
          if [[ "$remove_extra" == "true" ]]; then
            if [[ ${#to_remove[@]} -eq 0 ]]; then
              echo "No extra cost center members to remove (remove_extra_members=true)."
            elif ! remove_cost_center_members "$cc_id" "${to_remove[@]}"; then
              failures=$((failures + 1))
            fi
          fi
        fi
        rm -f "$members_tmp"

        budget_label="$name"
        [[ ${#teams_list[@]} -gt 1 ]] && budget_label="$name ($team_slug)"
        payload="$(build_budget_payload "cost_center" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json" "" "$cc_id")"
        if ! upsert_budget "$budget_label" "cost_center" "$sku" "entity" "$cost_center" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload" "$cc_id"; then
          failures=$((failures + 1))
        fi
        done
        continue
      fi

      # ── total_spend — per-member user budgets ───────────────────────────────
      # The shared-pool allotment is per user with no group-level construct, so
      # capping pool + additional means giving every member their own user budget.
      # Members are unioned across all listed teams and deduped, so a user in two
      # of the policy's teams is budgeted once.
      echo "Coverage: total spend (shared pool + additional) -> per-member user budgets"
      # Group the per-member budget records under this policy's teams in the summary.
      SUMMARY_GROUP="${teams_list[*]}"

      members_tmp="$(mktemp)"
      union_tmp="$(mktemp)"
      fetch_failed=0
      for team_slug in "${teams_list[@]}"; do
        echo "Source: $(team_source_label "$source_org" "$source_enterprise" "$team_slug")"
        if ! fetch_team_logins "$source_org" "$source_enterprise" "$team_slug" >"$members_tmp"; then
          echo "ERROR: Failed to fetch members for team '$team_slug' in policy '$name'" >&2
          echo "HINT: Check that the token has org/enterprise read permissions and the team slug is correct." >&2
          fetch_failed=1
          break
        fi
        cat "$members_tmp" >>"$union_tmp"
      done
      rm -f "$members_tmp"
      if [[ "$fetch_failed" == "1" ]]; then
        rm -f "$union_tmp"
        failures=$((failures + 1))
        continue
      fi
      mapfile -t logins < <(sort -u "$union_tmp")
      rm -f "$union_tmp"
      echo "Unique team members found: ${#logins[@]}"

      if [[ ${#logins[@]} -eq 0 ]]; then
        echo "WARN: No members found for policy '$name'; skipping."
        continue
      fi

      for login in "${logins[@]}"; do
        if conflict_should_skip "$i" "$login"; then
          echo "Skip user '$login' for policy '$name' (budget conflict: a later policy wins this user; see Conflicts in the summary)."
          continue
        fi
        payload="$(build_budget_payload "user" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json" "$login")"
        if ! upsert_budget "$name ($login)" "user" "$sku" "user" "$login" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload"; then
          failures=$((failures + 1))
        fi
      done
      ;;

    organization)
      # scope: organization is dual-track like team, but keyed on the org itself
      # and written on the org billing endpoint (parent = org). organization: is
      # required and already normalized into p_org above.
      org="$p_org"
      if ! has_value "$org"; then
        echo "ERROR: policy '$name' (organization) must include an organization" >&2
        failures=$((failures + 1))
        continue
      fi
      # Parent = org -> reconcile/write against the org billing endpoint.
      ACTIVE_BUDGETS_ENDPOINT="$(org_budgets_endpoint "$org")"
      load_budget_cache_if_needed "$ACTIVE_BUDGETS_ENDPOINT"
      ACTIVE_BUDGETS_CACHE="${BUDGET_CACHE_BY_EP[$ACTIVE_BUDGETS_ENDPOINT]}"
      SUMMARY_GROUP="$org"
      echo "Parent: organization '$org' -> budgets endpoint $ACTIVE_BUDGETS_ENDPOINT"

      # ── additional_spend — one org-scope budget ─────────────────────────────
      # Collective metered spend is a group concern; an org-scope budget caps the
      # whole org's additional usage. No membership work, no cost center.
      if [[ "$coverage" == "additional_spend" ]]; then
        echo "Coverage: additional spend (metered) -> single organization-scope budget on '$org'"
        payload="$(build_budget_payload "organization" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json" "" "$org")"
        if ! upsert_budget "$name" "organization" "$sku" "entity" "$org" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload" "$org"; then
          failures=$((failures + 1))
        fi
        ACTIVE_BUDGETS_ENDPOINT=""
        ACTIVE_BUDGETS_CACHE=""
        continue
      fi

      # ── total_spend — per-member user budgets ───────────────────────────────
      # Cap each org member's pool + additional spend with an individual user
      # budget (always hard-stop), same shape as a team total_spend policy.
      echo "Coverage: total spend (shared pool + additional) -> per-member user budgets"
      if ! member_logins_file members_tmp org "$org" "" ""; then
        echo "ERROR: Failed to fetch members for organization '$org' in policy '$name'" >&2
        echo "HINT: Check that the token has org read permissions and the organization login is correct." >&2
        ACTIVE_BUDGETS_ENDPOINT=""
        ACTIVE_BUDGETS_CACHE=""
        failures=$((failures + 1))
        continue
      fi
      mapfile -t logins <"$members_tmp"
      echo "Organization members found: ${#logins[@]}"
      if [[ ${#logins[@]} -eq 0 ]]; then
        echo "WARN: organization '$org' has no readable members for policy '$name'; skipping."
        ACTIVE_BUDGETS_ENDPOINT=""
        ACTIVE_BUDGETS_CACHE=""
        continue
      fi
      for login in "${logins[@]}"; do
        if conflict_should_skip "$i" "$login"; then
          echo "Skip user '$login' for policy '$name' (budget conflict: a later policy wins this user; see Conflicts in the summary)."
          continue
        fi
        payload="$(build_budget_payload "user" "$amount" "$prevent" "$sku" "$btype" "$will_alert" "$recipients_json" "$login")"
        if ! upsert_budget "$name ($login)" "user" "$sku" "user" "$login" "$amount" "$prevent" "$will_alert" "$recipients_json" "$payload"; then
          failures=$((failures + 1))
        fi
      done
      ACTIVE_BUDGETS_ENDPOINT=""
      ACTIVE_BUDGETS_CACHE=""
      ;;

    *)
      echo "ERROR: policy '$name' has unknown or missing type '$policy_type'. Valid types: all_users, enterprise, cost_center, team, organization, user." >&2
      failures=$((failures + 1))
      ;;
  esac
done

if ((failures > 0)); then
  echo "Completed with $failures failure(s)." >&2
  exit 1
fi

echo "Budget policy apply flow completed (dry_run=$DRY_RUN)."
