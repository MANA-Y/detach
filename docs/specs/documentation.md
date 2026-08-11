# Documentation and agent-context specification

## Outcome

Codex and Claude Code receive the same small durable instruction core, discover
only task-relevant detailed specs, and use focused tests while iterating.
Hosted pull-request CI is the deterministic merge-readiness authority.

## Invariants

- Exactly one case-insensitive agent instruction file exists: `AGENTS.md`.
- `CLAUDE.md` contains exactly `@AGENTS.md`; it contains no duplicate
  instructions or additional imports.
- Root instructions stay below 200 lines and 8 KiB. Detailed architecture does
  not return to the automatic startup context.
- No individual spec exceeds 12 KiB. Read more than one only when a change
  crosses real subsystem boundaries.
- `AGENTS.md` contains one small human-readable context map. There is no second
  routing DSL or tool for an agent to learn.
- New or changed English text in `README.md` and `docs/` uses
  [ASD-STE100 Issue 9](https://www.asd-ste100.org/). Product names, paths,
  commands, and identifiers are project technical terms. A document does not
  claim verified STE compliance unless a reviewer checks it against the
  official standard.
- Durable specs describe current contracts. Ignored `docs/work/` contains
  temporary executable plans. Imports are not used for detailed specs because
  Claude expands imports eagerly.
- Ignored `presentations/` contains internal presentation sources. Git and the
  quality gate do not treat these files as repository inputs.
- Fast local diagnostics close the edit loop. They never claim merge readiness.
  Hosted pull-request CI runs the full repository gate on the exact change and
  is the sole ordinary merge-readiness authority.
- `scripts/test critical`, `unit`, `coverage`, `smoke`, and `full` are the
  stable human entry points for the high-risk logic loop, complete Swift loop,
  measured coverage loop, freshly packaged product smoke, and exhaustive local
  repository diagnostic respectively. Each supports `--plan`. No command in
  this group is merge-readiness evidence.
- Resume evidence retains stage timing and digest-bound logs, binds its parent,
  requires the same authority, and cannot turn a prior time-budget regression
  into authoritative evidence.
- A local timing-budget failure creates performance work. Warm-cache or
  variance reruns cannot turn it into readiness; an unchanged rerun is allowed
  only for an evidenced unrelated external transient whose cause is recorded.
- Pull-request CI runs every functional check once and the timing-policy
  ratchets. It does not enforce reference-machine wall or per-stage timing
  ceilings. The workflow has a ten-minute overall deadline.
- A deterministic static dashboard reads only validated gate evidence. The
  same artifact opens locally and deploys to GitHub Pages only after a green
  `main` repository run. Its deploy job alone has Pages write permission.
- The active GitHub ruleset for `main` has no bypass actors. It requires the
  GitHub Actions `quality-gates` job. An administrator cannot use an unchecked
  push as a substitute for CI. A release commit first gets the same check on
  its temporary release ref.
- By default, put a ready task-scoped change on a topic branch. Review the
  staged public diff, commit it, and push it. Merge it only after the required
  PR check passes. Then verify that local `main` and upstream `main` are equal.
  The owner can ask to keep the change local.
- `tests/docs-contract.sh` enforces this structure and runs inside the
  static quality stage.

## Spec lifecycle

Use a direct edit for a small, obvious task. Use the ExecPlan template when
work crosses subsystems, contains material unknowns, changes security/release
contracts, or needs a resumable multi-session handoff. Keep the plan
self-contained and current while working. Promote only stable outcomes and
invariants into the durable spec.

When agent behavior repeatedly fails, prefer a deterministic check. If behavior
cannot be enforced mechanically, update the narrow spec. Change `AGENTS.md`
only for a rule needed on most tasks.

## Verification

Run `tests/docs-contract.sh` and `tests/test-suite-contract.sh`, inspect the
context map for the affected area, and run the focused local diagnostics. The
required pull-request job supplies final merge evidence.
