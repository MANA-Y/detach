# <Outcome-oriented task title>

This ExecPlan is a living, self-contained implementation specification. Keep
it current while work proceeds. It lives under ignored `docs/work/` and is
not a durable product contract.

## Purpose and observable outcome

State what a user or operator can do after this change and how they can observe
that it works.

## Scope and non-goals

Name the behavior and components in scope. State important boundaries that must
remain unchanged.

## Contract delta

For each affected `README.md` contract or durable spec, state the current and
target behavior. Classify each requirement as ADDED, MODIFIED, or REMOVED. Name
its user journey, scenarios, and acceptance evidence. If behavior and
invariants do not change, write `No contract change` and give the evidence.

## Requirements and acceptance evidence

For every requirement, name the authoritative evidence that will prove it:
test output, runtime behavior, artifact inspection, or a manual gate. Treat
missing or indirect evidence as incomplete.

## Relevant context

Name exact source files, durable specs, interfaces, and terms needed by someone
with only this working tree and this plan. Summarize necessary external research
and link its primary source.

## Pre-implementation review

Before primary implementation, review the contract delta, scope, non-goals,
and acceptance evidence. Record the reviewer, approval source, and `Ready` or
`Blocked` with a reason. The request is approval only when it fixes the same
target behavior and boundaries. Ask the owner to resolve each material product,
security, or release choice that it does not fix. Revise this checkpoint when a
discovery changes the contract delta.

## Plan and progress

- [ ] Add dependency-ordered milestones with concrete outcomes.
- [ ] Update this list at every stopping point.
- [ ] Keep implementation, tests, docs, and migration work visible.

## Decisions

Record each material choice, alternatives considered, and why the choice serves
the requirements.

## Surprises and discoveries

Record facts learned from code, experiments, or tests that change the plan.

## Verification

List fast per-milestone checks and the final impact-selected gate. Include
expected observable results, not only command names.

## Outcomes and retrospective

At completion, compare the result with every requirement, name remaining gaps,
and summarize evidence. Promote stable invariants to `docs/specs/`. Put a safe
summary of the contract delta, durable decisions, and evidence in the pull
request. Do not copy private ExecPlan content or temporary history.
