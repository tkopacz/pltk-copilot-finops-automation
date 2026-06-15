# Cost Center Members Config Patterns (v2)

Cost center member sync lives under `team_cost_center_mappings:` in the merged v2 file
`config/copilot-finops.yml` (or `config/copilot-finops.local.yml`). A v2 file declares `version: 2`;
`ai_credit_spend_policies` and `team_cost_center_mappings` are both optional (include only what you need).

> **Authoritative shape:** the full mapping field list and rules live in
> `schemas/v2/copilot-finops.schema.json` and `config/copilot-finops.example.yml`. This file shows
> idiomatic examples and the strict-vs-additive judgment — if it disagrees with the schema, the schema wins.

> Editing an existing v1 file (`config/cost-center-members.yml`)? Use the v1 `mappings:` shape
> (`source` / `target` / `sync`) and validate with `... teams`. See the v1 → v2 map in `SKILL.md`.

## Empty / sync-only Config

```yaml
version: 2
enterprise_slug: your-enterprise
team_cost_center_mappings: []
```

## Naming

Use predictable cost center names:

- Org team cost center: `cc-org-{org}-{team}`
- Enterprise team cost center: `cc-ent-{enterprise}-{team}`

Use the bare team slug. `organization:` selects an org team source; omit it for an enterprise team
(the enterprise is inferred). `enterprise:` and `organization:` are mutually exclusive.

## Org Team Strict Sync

Adds missing users and removes extra users from the cost center.

```yaml
team_cost_center_mappings:
  - name: cc-org-your-org-platform-engineering
    description: Keep org team platform-engineering exactly in sync with its cost center.
    organization: your-org
    team: platform-engineering
    cost_center: cc-org-your-org-platform-engineering
    remove_extra_members: true
```

## Enterprise Team Additive Sync

Adds missing users but keeps extra/manual cost center members.

```yaml
team_cost_center_mappings:
  - name: cc-ent-your-enterprise-ai-leads
    description: Add enterprise team ai-leads members to its cost center without removing extras.
    team: ai-leads
    cost_center: cc-ent-your-enterprise-ai-leads
```

## Explicit Additive Sync

Use this when the user wants the intent visible in review — set `remove_extra_members: false`
explicitly on the mapping (same effect as omitting it):

```yaml
team_cost_center_mappings:
  - name: cc-ent-your-enterprise-ai-leads
    team: ai-leads
    cost_center: cc-ent-your-enterprise-ai-leads
    remove_extra_members: false
```

## Strict vs Additive Decision

Use strict sync (`remove_extra_members: true`) when:

- The cost center should contain exactly the team members.
- Removed team members should stop being charged to that cost center.

Use additive sync (omit or `false`) when:

- The cost center also contains manually managed users.
- Another process manages removals.
- The user is testing and wants lower blast radius.

## Validate and dry-run

See `./validation.md` for the full command matrix (v1/v2, dry-run, workflow inputs). Quick check after authoring:

```bash
scripts/validate-config.sh config/copilot-finops.yml all
```
