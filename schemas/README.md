# Config schemas

JSON Schemas that validate the YAML config files in [`config/`](../config). They power two things:

1. **Editor validation** — red squiggles, autocomplete, and hover docs via the Red Hat **YAML**
   extension (wired up in [`.vscode/settings.json`](../.vscode/settings.json)).
2. **CI / local validation** — the schema layer in
   [`scripts/validate-config.sh`](../scripts/validate-config.sh), which runs `check-jsonschema`
   against the matching schema before the semantic re-checks.

The current v2 schema also carries standard JSON Schema annotations (`title`, `description`,
`default`, `examples`, and `$comment`) so editors and generated docs can explain fields without
changing validation behavior. Enum-like fields use the standards-compliant `oneOf` + `const` +
`title` + `description` pattern, rather than non-standard `enumDescriptions` / `meta:enum`, so each
allowed value can have its own description while remaining portable across validators.

| Schema | Validates | Status |
| --- | --- | --- |
| `v2/copilot-finops.schema.json` | `config/copilot-finops*.yml` (merged budgets + member mappings) | **current** |
| `v1/budget-policies.schema.json` | `config/budget-policies*.yml` | frozen |
| `v1/cost-center-members.schema.json` | `config/cost-center-members*.yml` | frozen |

> **v2 is the documented contract.** v1 is frozen and still validates existing split files; new
> config should use the v2 merged file. The rest of this document is a complete field-by-field
> reference for v2, followed by a short v1 note.

## How validation is layered

`scripts/validate-config.sh <file> <all|budgets|teams>` validates in two passes:

1. **JSON Schema (`check-jsonschema`)** — structure, types, enum-like values, typo protection
   (`additionalProperties: false`), and (for v2) the *structural* cross-field rules. Install it with
   `pipx install check-jsonschema` for the full local check. If it is missing, the script prints a
   warning and runs the bash re-checks only; the workflows always install it so CI enforces the
   schema.
2. **Semantic re-checks (bash, in `validate-config.sh`)** — the same structural rules again for
   friendlier messages on billing-sensitive config, plus the rules a schema cannot express.

The split matters: a JSON Schema can enforce *shape* and *structural* relationships between fields in
one document, but it cannot read live GitHub state or resolve runtime precedence. So three classes of
rule deliberately stay in the scripts, never in the schema:

- **Enterprise slug resolution** — `--enterprise-slug` (CLI/workflow) > a per-entry `enterprise:` >
  the top-level `enterprise_slug`. At least one must resolve at apply/sync time.
- **Live lookups** — cost center name → ID, and team membership reads from the GitHub API.
- **Value defaulting** — e.g. `stop_at_limit` defaults to `true` when omitted.

## Versioning model

A config declares its contract version with the top-level `version` field. Each version has a
**frozen** schema under `schemas/v<N>/`; `validate-config.sh` reads `version` and validates against
the matching folder. This is the safety guarantee: evolving the contract never edits the schema an
already-shipped config validates against.

- **v2** *requires* `version: 2` (so the file routes to `schemas/v2/`). The v2 schema targets JSON
  Schema **draft 2020-12** because the budget-policy baseline cardinality rule uses
  `contains` + `minContains`/`maxContains`.
- **v1** omits `version` (or sets `version: 1`) and routes to `schemas/v1/` (draft-07, frozen).

Only use a version that has a matching `schemas/v<N>/` directory.

## Editor and documentation annotations

The v2 schema intentionally stays standards-compliant while still giving users rich authoring help:

- `title` gives editors and generated docs short display names for fields and enum-like values.
- `description` explains the field or allowed value in hover text and generated reference docs.
- `default` documents defaults that the scripts apply, such as `stop_at_limit: true`,
   `alert_admins: []`, `remove_extra_members: false`, and the optional top-level lists defaulting to
   `[]`. Defaults are annotations only; validators do **not** mutate config files.
- `examples` provides public-safe sample values for slugs, teams, cost centers, amounts, and alert
   recipients.
- `$comment` labels schema-internal rule blocks so maintainers can line them up with this document
   and `AGENTS.md`; validators ignore these comments.

For enum-like values, the v2 schema uses `oneOf` entries with `const`, `title`, and `description`:

```json
"scope": {
   "oneOf": [
      { "const": "all_users", "title": "All users", "description": "Default per-user budget..." },
      { "const": "team", "title": "Team", "description": "Materialized from team membership..." }
   ]
}
```

This is standard JSON Schema. Avoid non-standard enum documentation keywords such as
`enumDescriptions`, `markdownEnumDescriptions`, or `meta:enum` unless a future change explicitly
targets one specific documentation generator or editor.

---

# v2 schema reference (`v2/copilot-finops.schema.json`)

v2 merges the two v1 files into one document and renames the vocabulary so it reads in plain billing
terms. The whole contract is one object with two optional lists.

## Top-level object

| Field | Type | Required | Description |
| --- | --- | --- | --- |
| `version` | `2` (const) | **yes** | Selects the v2 schema. Must be exactly `2`. |
| `enterprise_slug` | string | no¹ | GitHub Enterprise slug. May instead come from `--enterprise-slug` or a per-entry `enterprise:`. |
| `ai_credit_spend_policies` | array of [policy](#ai_credit_spend_policies-items) | no | Budget policies to reconcile. Omit (or `[]`) to skip budgets entirely. |
| `team_cost_center_mappings` | array of [mapping](#team_cost_center_mappings-items) | no | Team → cost center membership syncs. Omit (or `[]`) to skip member sync entirely. |
| `api` | object | no | Advanced REST endpoint template overrides. Leave unset for github.com; only set when proxying the API. Not shown in example configs. |

¹ Optional *in the schema*, but the apply/sync scripts require an enterprise slug to resolve at
runtime from one of the three sources above.

`additionalProperties: false` at every level: any unknown or misspelled key is rejected.

The smallest valid v2 file is a no-op:

```yaml
version: 2
enterprise_slug: your-enterprise
```

## `ai_credit_spend_policies[]` items

A single budget policy. `scope` selects what the budget caps; the other required/allowed fields
depend on `scope` (see [the per-scope rules](#per-scope-rules)).

| Field | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `scope` | enum | **yes** | — | One of `all_users`, `enterprise`, `user`, `cost_center`, `team`, `organization`. |
| `amount` | integer ≥ 0 | **yes** | — | Budget cap in whole USD. Maps to `budget_amount`. |
| `name` | string | no | — | Local label for logs and the `--policy-name` filter. Never sent to the API. |
| `description` | string | no | — | Human-readable note. |
| `users` | array of string (min 1, unique) | conditional | — | GitHub logins to budget; each gets its own hard-stop user budget. **Required** for `scope: user`; each login is sent as a budget's `user` field. Forbidden for every other scope. |
| `credit_scope` | enum | conditional | — | `pool_then_metered` or `metered_only`. **Required** for `scope: team` and `scope: organization`; forbidden for the others. See [credit_scope](#credit_scope-what-the-budget-covers). |
| `enterprise` | string | no | — | Per-entry enterprise slug override. **Mutually exclusive with `organization`.** |
| `organization` | string | conditional | — | Org login. On `scope: team` it marks an org-team membership source; on `scope: organization` it names the org (and routes to the org billing endpoint). **Required** for `scope: organization`. Mutually exclusive with `enterprise`. |
| `teams` | array of string (min 1, unique) | conditional | — | Bare team slugs (no `ent:` prefix); the policy is applied to each. **Required** (one or more) for `scope: team`. |
| `cost_center` | string | conditional | — | Cost center name (resolved to its ID at apply time). **Required** for `scope: cost_center`; an optional explicit destination for a **single-team** `scope: team` + `credit_scope: metered_only` policy (derived when omitted, and forbidden when more than one team is listed). |
| `stop_at_limit` | boolean | no | `true` | Hard-stop usage at the cap (maps to `prevent_further_usage`). Forced `true` where user-level budgets are produced (see below). |
| `alert_admins` | array of string | no | `[]` | Logins to alert when the budget is hit. A non-empty list enables alerting. |
| `remove_extra_members` | boolean | no | `false` | Only valid on `scope: team` + `credit_scope: metered_only`. `true` prunes cost-center members who left the team; `false` is additive. |

### `scope`: what the budget caps and how it materializes

| `scope` | GA `budget_scope` produced | What it does |
| --- | --- | --- |
| `all_users` | `multi_user_customer` | Default per-user budget for every licensed user. Always hard-stop. |
| `enterprise` | `enterprise` | Caps total enterprise **metered** spend after the shared pool. |
| `user` | `user` ×N | One hard-stop budget per login in `users`. Written on the **enterprise** endpoint. |
| `cost_center` | `cost_center` | Caps one named cost center's metered spend. Identified by `cost_center` (sent as `budget_entity_name`). |
| `team` | `user` ×N **or** `cost_center` ×teams | Applied to each team in `teams`; the track is chosen by `credit_scope` (next section). Written on the **enterprise** endpoint. |
| `organization` | `user` ×N **or** `organization` | Materialized from org membership; the track is chosen by `credit_scope`. Written on the **org** billing endpoint (`/organizations/{org}/settings/billing/budgets`). |

### `credit_scope`: what the budget covers

Only `scope: team` and `scope: organization` are "dual-track" — they expand into budgets based on a
team's or org's membership, and `credit_scope` picks which kind:

| `credit_scope` | `scope: team` produces | `scope: organization` produces | Hard-stop |
| --- | --- | --- | --- |
| `pool_then_metered` | one **user** budget per member, unioned across the listed teams (covers shared pool → then metered) | one **user** budget per org member | Always `true` (forced) |
| `metered_only` | one **cost center** budget per listed team's collective metered spend (+ populates each cost center with current members) | one **organization**-scope budget for the org's collective metered spend | Optional |

### Per-scope rules

The schema encodes these as `allOf` + `if`/`then` blocks. Required = must be present; forbidden = the
schema rejects the field for that scope.

| `scope` | Requires | Forbids | `stop_at_limit` |
| --- | --- | --- | --- |
| `all_users` | — | `teams`, `cost_center`, `credit_scope`, `organization`, `remove_extra_members`, `users` | forced `true` |
| `enterprise` | — | `teams`, `cost_center`, `credit_scope`, `organization`, `remove_extra_members`, `users` | optional |
| `user` | `users` | `teams`, `cost_center`, `credit_scope`, `organization`, `remove_extra_members` | forced `true` |
| `cost_center` | `cost_center` | `teams`, `credit_scope`, `organization`, `remove_extra_members`, `users` | optional |
| `team` | `teams`, `credit_scope` | `users` | see credit_scope rows |
| `team` + `pool_then_metered` | (above) | `cost_center`, `remove_extra_members` | forced `true` |
| `team` + `metered_only` | (above) | `cost_center` when >1 team listed | optional |
| `organization` | `organization`, `credit_scope` | `teams`, `cost_center`, `enterprise`, `remove_extra_members`, `users` | see credit_scope rows |
| `organization` + `pool_then_metered` | (above) | — | forced `true` |

Across **every** policy, `enterprise` and `organization` are mutually exclusive
(`not: { required: [enterprise, organization] }`).

"Forced `true`" means the schema pins `stop_at_limit` to `{ "const": true }` — setting it `false`
there is a validation error, because user-level (per-member) budgets always hard-stop.

## `team_cost_center_mappings[]` items

A standalone, ongoing team → cost center membership sync (independent of any budget).

| Field | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `team` | string | **yes** | — | Source team slug (bare, no `ent:` prefix). |
| `cost_center` | string | **yes** | — | Destination cost center name (resolved to its ID at sync time). |
| `name` | string | no | — | Local label for logs and the `--mapping-name` filter. |
| `description` | string | no | — | Human-readable note. |
| `organization` | string | no | — | Org login for an org-team source. **Mutually exclusive with `enterprise`.** Omit for an enterprise team. |
| `enterprise` | string | no | — | Per-entry enterprise slug override for an enterprise-team source. Mutually exclusive with `organization`. |
| `remove_extra_members` | boolean | no | `false` | `true` = strict reconcile (remove cost-center members no longer in the team); `false` = additive. |

As with policies, `enterprise` and `organization` are mutually exclusive on a mapping.

## What the v2 schema does *not* enforce

These stay in `scripts/validate-config.sh` (bash re-checks) and the apply/sync scripts, because they
need runtime context:

- Enterprise slug resolution and the requirement that one slug resolves.
- Live cost center name → ID resolution and team-membership reads.
- Value defaulting (`stop_at_limit` → `true`, `alert_admins` → `[]`, `remove_extra_members` →
  `false`).
- Budget reconciliation / conflict detection (last-policy-wins for duplicate per-member budgets).

---

# v1 schemas (frozen)

`v1/budget-policies.schema.json` and `v1/cost-center-members.schema.json` validate the split files
`config/budget-policies*.yml` and `config/cost-center-members*.yml`. They are **shape-only**: they
check structure, types, and enums but intentionally do **not** encode cross-field semantic rules
(those live entirely in `scripts/validate-config.sh` and the apply/sync scripts).

v1 stays fully supported by the per-type workflows and by `validate-config.sh ... budgets|teams`, but
it is frozen — do not edit the v1 schemas to change the contract. The v1 → v2 vocabulary map:

| v1 | v2 |
| --- | --- |
| `budget_policies:` (list) | `ai_credit_spend_policies:` (optional) |
| `mappings:` (list) | `team_cost_center_mappings:` (optional) |
| `type` | `scope` |
| `type: universal` | `scope: all_users` |
| `coverage: total_spend` / `additional_spend` | `credit_scope: pool_then_metered` / `metered_only` |
| `source: {enterprise, team_slug}` | `teams:` (budgets) / `team:` (mappings); enterprise inferred |
| `source: {org, team_slug}` | `organization:` + `teams:` (budgets) / `team:` (mappings) |
| `target.cost_center` | `cost_center:` |
| `budget.amount` | `amount` |
| `budget.prevent_further_usage` | `stop_at_limit` |
| `budget.alerting.{will_alert, alert_recipients}` | `alert_admins` (non-empty enables alerting) |
| `sync.remove_extra_members` | `remove_extra_members` |
| `budget-policies.yml` + `cost-center-members.yml` | `copilot-finops.yml` |

---

## Adding a new version (v3+)

1. Add a new `v<N>/` folder with the schema(s) for that version. **Do not** edit a previously shipped
   `v<M>/`. A new version may restructure the contract — v2, for example, merged the two v1 schemas
   into one `v2/copilot-finops.schema.json`.
2. Set the new `version` only in configs that adopt the new shape; older configs are untouched.
3. Put new cross-field rules where they belong: *structural* rules (conditional required/forbidden
   fields, enums, simple constraints) can live in the schema as of v2; *runtime/live* rules stay in
   `scripts/validate-config.sh` and the apply/sync scripts. Branch on the version when behavior
   diverges.
4. Update the editor mapping in [`.vscode/settings.json`](../.vscode/settings.json) so each version's
   config glob points at its schema (or use inline `# yaml-language-server: $schema=...` modelines
   per file for mixed versions).
5. Extend the schema tests: add `tests/cases/v<N>/<schema>.yml` manifests (the runner discovers
   `tests/cases/v*/` automatically), then keep
   [`tests/run-schema-tests.sh`](../tests/run-schema-tests.sh) green.
6. Update the skill and docs per [`AGENTS.md`](../AGENTS.md).

## Tests

The schemas are contract-tested by [`tests/run-schema-tests.sh`](../tests/run-schema-tests.sh), which
meta-validates each schema and validates the version-scoped cases under
[`tests/cases/`](../tests/cases) against it. Each case has a `name`, a `valid` flag (`true` must
pass, `false` must be rejected), an optional `expect_error` substring (so a case cannot fail for the
wrong reason), and the `config` document. Run it after any schema change.
