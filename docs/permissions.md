# Permissions

Use a dedicated token in `COPILOT_FINOPS_TOKEN` for enterprise Copilot billing operations.

## Roles

The GA Budget and usage management (enhanced billing) endpoints are accessible to:

- **Enterprise owners**
- **Billing managers**
- **Organization owners** (organization-level and cost center budgets; cost center APIs)

Creating, updating, and deleting enterprise budgets and cost centers requires an enterprise admin or billing manager. Deleting a budget or cost center requires an enterprise admin.

## Token scopes/permissions

For the full solution, create a dedicated classic PAT with the required scopes preselected:

[Create `COPILOT_FINOPS_TOKEN`](https://github.com/settings/tokens/new?description=Copilot%20FinOps%20Automation&scopes=admin%3Aenterprise,read%3Aenterprise,read%3Aorg)

The link preselects `admin:enterprise`, `read:enterprise`, and `read:org`. After creating the token, authorize it for SAML SSO if your enterprise or organization requires SSO authorization.

The token usually needs:

- Enterprise billing management — required for the budgets and cost center APIs:
  - `GET|POST|PATCH|DELETE /enterprises/{enterprise}/settings/billing/budgets...`
  - `GET|POST|PATCH|DELETE /enterprises/{enterprise}/settings/billing/cost-centers...` (including `/resource`)
- Organization read access for org team membership (`read:org`).
- Enterprise read access for enterprise team membership (`read:enterprise` or "Enterprise teams" read).

Use the least privilege that supports the workflows you enable:

| Workflow | Needs write access? | Main permissions |
| --- | ---: | --- |
| Audit | No | Read enterprise billing/cost centers, read org or enterprise team membership. |
| Sync cost center members | Yes | Read team membership, read cost centers, add/remove cost center resources. |
| Apply budgets | Yes | Read/list budgets, create/update budgets, and read/create cost centers for team budgets that cap metered usage only (`team` + `credit_scope: metered_only`). |

If you only use `enterprise` and `all_users` budget policies, the token does not need org team membership read access. If you use org or enterprise `team` policies, it does.

If you do not use org teams anywhere in config, you can omit `read:org`. If you do use org teams, keep it.

## Enterprise team tokens

Enterprise teams (v1 `source.enterprise`; v2 a `team` with no `organization:`) use `/enterprises/{enterprise}/teams/{team_slug}/memberships`.
This endpoint requires a classic PAT with `read:enterprise` scope, or a fine-grained token with
the "Enterprise teams" read permission.

## Organization budgets (v2 `scope: organization`)

A `scope: organization` budget is written on the org billing endpoint
(`/organizations/{org}/settings/billing/budgets`) and reads org membership from
`/orgs/{org}/members`. The authenticated user must be an organization admin or billing manager for
that org (a fine-grained token needs organization "Administration" write for create/update). The
per-member track also reads `read:org` membership.

## Safety recommendations

- Protect `config/**` and `.github/workflows/**` with required reviews and CODEOWNERS.
- Keep manual mutating workflows defaulted to `dry_run=true`, and keep schedules disabled until reviewed file-based config is ready.
- Use branch protection on `main`.
- Prefer a dedicated automation token that can be rotated without affecting a human's everyday account.
- Rotate the token immediately if it ever appears in logs, reports, issues, commits, or screenshots.
