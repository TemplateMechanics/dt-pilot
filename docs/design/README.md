# Design Proposals

This directory holds design docs for proposed dt-pilot enhancements. Each doc is a contract between proposer and implementer: it captures the problem, the chosen approach, the rejected alternatives, and the acceptance criteria so the implementation PR doesn't drift.

## Lifecycle

1. **Draft.** A proposal lands here as a PR. Status: `Draft`.
2. **Accepted.** Maintainers approve the proposal as written. Status: `Accepted`. Approval lives in the merged proposal PR; the doc is updated to `Accepted` in the implementation PR's first commit.
3. **Implemented.** The implementation PR cross-links to the design doc and updates the doc's status. Status: `Implemented (<PR #>)`.
4. **Superseded / Rejected.** If a later proposal replaces this one, or implementation reveals the design was wrong, the doc keeps a `Superseded by ...` or `Rejected (reason)` line at the top rather than being deleted.

Design docs are never silently rewritten after acceptance — significant changes go in a follow-up proposal.

## Active proposals

| # | Title | Status |
|---|---|---|
| 001 | [Multi-backend skeleton](MULTI-BACKEND-SKELETON.md) | Implemented (#10) |
| 002 | [Scheduled catalog refresh](SCHEDULED-CATALOG-REFRESH.md) | Draft |
| 003 | [Terraform backend](TERRAFORM-BACKEND.md) | Draft |

## Why design docs

The bootstrap series (PRs #1–#8) was a single decided architecture executed sequentially. The next wave of work is genuinely optional and has real trade-offs: multi-backend support, automation of catalog maintenance, and bringing in a second IaC tool each have multiple reasonable shapes. Writing them down before coding forces those trade-offs into the open where they can be reviewed cheaply, instead of discovered expensively in the diff.

## Format

Every doc follows the same outline:

1. **Status / Owner / Last updated**
2. **Problem**
3. **Goals / Non-goals**
4. **Proposed design**
5. **Migration / rollout**
6. **Alternatives considered**
7. **Open questions**
8. **Acceptance criteria** (what makes the implementation PR mergeable)

Keep proposals short — one screenful per major section is the target. Long proposals are usually two proposals.
