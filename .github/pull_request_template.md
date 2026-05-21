<!--
Thanks for contributing to dt-pilot.

Fill out every section. Squash-merge is the only allowed merge style, so the
PR title becomes the commit subject — write it as a Conventional Commit.

Title format:  <type>(<optional scope>): <short imperative summary>
Examples:
  feat(scripts): add Invoke-MonacoDelete wrapper with deletefile guard
  fix(ci): pin Monaco to 2.18 in validate workflow
  docs(skill): document Grail bucket selection in DQL primer
-->

## Summary

<!-- 1-3 bullets describing the change at a high level -->

## Why

<!-- The motivation. What problem does this fix or capability does this unlock?
     If this PR was opened by an AI agent, explain what user prompt drove it. -->

## How a reviewer should verify

<!-- Concrete steps. If the change adds a script, show the invocation.
     If it changes the manifest schema, show a manifest that now validates. -->

```powershell
# example:
./scripts/monaco/Validate-Monaco.ps1 -Path examples/baseline-stack
./scripts/monaco/Invoke-MonacoDryRun.ps1 -Path examples/baseline-stack -Environment dev
```

## Risk

<!-- What could go wrong? Is anything irreversible (deletefile changes, schema
     tightening, sync-check additions)? Call out blast radius. -->

## Checklist

- [ ] Branch name follows `feat/`, `fix/`, `chore/`, `docs/`, `refactor/`, or `test/` convention
- [ ] No secrets, tenant IDs, or live environment URLs committed
- [ ] `./scripts/Pre-Commit.ps1` passes locally (or N/A — explain why)
- [ ] CI is green
- [ ] Updated `CHANGELOG.md` under `[Unreleased]` if user-visible
- [ ] Updated relevant docs under `docs/` (or N/A — explain why)
- [ ] If this regenerates reflected catalog output, the generated files are included in the same PR
