# Contributing

Thanks for improving this project.

## Before opening a pull request

- Do not include real enterprise slugs, team slugs, cost center names, user logins, generated reports, logs, JSONL summaries, or tokens.
- Keep examples generic and use placeholder names such as `your-enterprise`, `your-org`, and `platform-engineering`.
- Keep mutating workflows defaulted to `dry_run=true`.
- Avoid behavior changes that create, update, or delete live billing objects without an explicit dry-run path.
- When config, schema, workflow, issue-template, label, validation, or terminology requirements change, update `AGENTS.md` and `.github/skills/copilot-finops-config/` in the same pull request.

## Validation

Run the focused checks for the files you changed. For most changes, start with:

```bash
bash -n scripts/*.sh
tests/run-schema-tests.sh
scripts/validate-config.sh config/copilot-finops.example.yml all
awk 'NR==1 {next} /^---$/ {exit} {print}' .github/skills/copilot-finops-config/SKILL.md | yq eval '.' >/dev/null
git diff --check
```

Install `check-jsonschema` (`pipx install check-jsonschema`) so `validate-config.sh` also runs the JSON Schema layer locally and `tests/run-schema-tests.sh` can run; otherwise `validate-config.sh` warns and runs the semantic checks only.

When you change a config field, constraint, enum, default, policy type, the `version` field, or a `schemas/v<N>/` schema, extend the schema tests in the same change: append a valid case and an invalid case (with `expect_error`) to `tests/cases/v<N>/<schema>.yml`, and keep `tests/run-schema-tests.sh` green. See `## Schema Tests` in `AGENTS.md`.

If available, also run:

```bash
shellcheck scripts/*.sh
actionlint .github/workflows/*.yml
```

## Pull request notes

In the pull request description, include:

- What changed.
- Whether it affects a read-only or mutating workflow.
- What validation you ran.
