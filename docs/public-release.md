# Public Release Checklist

Use this checklist before publishing this repository, a fork, or a template copy.

## Remove private data

- Search tracked files for real enterprise slugs, organization names, team slugs, cost center names, user logins, alert recipients, and budget amounts.
- Replace live `config/copilot-finops.yml`, `config/budget-policies.yml`, and `config/cost-center-members.yml` values with public-safe placeholders or empty lists.
- Remove generated audit reports, run logs, JSONL summary files, screenshots, and copied workflow output.
- Verify no token, API response, or authorization header was pasted into docs, examples, issues, or commit messages.

## Publish safe defaults

Keep default config files valid but harmless. v2 merged file (both lists optional):

```yaml
version: 2
enterprise_slug: your-enterprise
```

v1 split files:

```yaml
enterprise_slug: your-enterprise
mappings: []
```

```yaml
enterprise_slug: your-enterprise
budget_policies: []
```

This lets scheduled workflows and validation steps fail less noisily while adopters are still configuring their private fork.

## v1 deprecation and sunset

The v2 merged config (`config/copilot-finops.yml`) is the tracked default for every workflow. The v1
split files are **frozen and deprecated**, not removed:

- `config/budget-policies.yml` and `config/cost-center-members.yml` still validate (`schemas/v1/`)
  and are still accepted by the per-type workflows' `*_config_file` inputs, which emit a deprecation
  notice in the run log and job summary.
- New config should use the merged v2 file. Convert an existing v1 pair with
  `scripts/migrate-v1-to-v2.sh`.

**Sunset decision (current):** keep v1 frozen and supported for now. Removing `schemas/v1/`, the v1
reading paths in the scripts, and the tracked v1 split files is a **separate future major change**,
announced ahead of time, and not done in this release. Until then, do not edit `schemas/v1/**` or the
v1 test cases. Revisit this decision when v1 usage has demonstrably wound down.

## Protect live deployments

- Use a private repository for live enterprise configuration whenever possible.
- Store `COPILOT_FINOPS_TOKEN` as a repository or organization secret, never in a file.
- Require reviews for `.github/workflows/**`, `config/**`, and scripts.
- Keep manual mutating workflows in `dry_run=true` until the audit and preview summaries are reviewed.
- Disable scheduled workflows in public demo repositories that are not connected to a real enterprise.

## Final checks

Run these before publishing:

```bash
scripts/validate-config.sh config/copilot-finops.example.yml all
[[ -f config/copilot-finops.yml ]] && scripts/validate-config.sh config/copilot-finops.yml all
[[ -f config/cost-center-members.yml ]] && scripts/validate-config.sh config/cost-center-members.yml teams
[[ -f config/budget-policies.yml ]] && scripts/validate-config.sh config/budget-policies.yml budgets
git diff --check
```

If `shellcheck`, `actionlint`, and `yq` are available, also run:

```bash
shellcheck scripts/*.sh
actionlint .github/workflows/*.yml
yq eval '.' .github/workflows/*.yml >/dev/null
```

## Copilot Customizations

- Review `AGENTS.md` and `.github/skills/copilot-finops-config/` before publishing.
- Keep the skill public-safe: no private enterprise slugs, team names, cost center names, users, budgets, reports, or tokens.
- If config requirements changed, make sure the skill references and docs were updated in the same change.
