# Quality gates

`quality/policy.tsv` is the single quality policy. It owns path impact,
capabilities, user journeys, requirements, stages, time limits, critical
sources, and release impact. `scripts/quality-policy` validates this source and
generates `quality/generated/policy.json`. Generated data must match the source.

`scripts/quality-gate` applies the policy. Local runs are diagnostics. Hosted
pull request CI runs every functional stage on the current merge commit and is
the only ordinary merge authority. Unknown paths select the full plan.

## Commands

- `scripts/quality-gate --plan --explain` shows affected capabilities,
  journeys, stages, and the path that selected each stage.
- `scripts/quality-gate` checks the working-tree diff and writes local
  diagnostic evidence.
- `scripts/quality-gate --base <ref>` also checks committed changes after the
  resolved merge base.
- `scripts/quality-gate --mode repository` runs every automated repository
  check. A local run remains diagnostic.
- `scripts/quality-gate --mode release` runs the complete pre-release plan. It
  omits only the recursive `scripts/release-version` test.
- `scripts/quality-gate --resume <run-dir>` reuses compatible passed stages.
  `--resume latest` selects the newest compatible local run.
- `scripts/quality-gate --stage <name>` reruns one diagnostic stage. It is not
  readiness evidence.
- `scripts/quality-history [RESULT_ROOT]` reports run and failure counts plus
  p50 and p95 wall and stage durations. It cannot produce readiness evidence.
- `scripts/quality-dashboard generate` writes deterministic static HTML and
  JSON. `scripts/quality-dashboard serve` binds to loopback and stops after its
  deadline.
- `scripts/quality-mutation` validates and runs the deterministic safety mutant
  corpus. Mutation work does not add to pull request latency.

`--without-release-budget` disables reference-Mac time comparisons. Hosted CI
uses this option because hosted timing is not release timing. Functional
checks, process deadlines, and static policy ratchets remain active. This
option does not make a local run authoritative.

## Authority and evidence

Every manifest records one authority:

- `local-diagnostic` for ordinary local work;
- `ci-merge` for the pull request merge commit;
- `ci-main` for the current `main` commit;
- `release` for the owner-confirmed release flow.

The repository gate writes private evidence under
`app/build/quality-gates/`. One run contains a schema-versioned TSV summary,
JUnit, Markdown, stage logs, safe environment facts, a provenance manifest,
and a digest inventory. Coverage runs also contain `quality-metrics.json`.

The manifest binds the evidence to the policy, authority, source and base
commits, exact input and plan fingerprints, selected capabilities, journeys,
stages, timestamps, inherited timing, parent evidence, environment, artifacts,
summary, and every stage log. A failure, timeout, interruption, blocked
dependency, unsafe file, malformed record, or digest mismatch cannot produce
PASS. Failure output gives the exact diagnostic rerun.

Resume requires the same policy, authority, source commit, base commit, and
input fingerprint. The old plan must contain every selected stage. Reused logs
keep their duration and digest. The new manifest binds the parent manifest.
Inherited wall time cannot become shorter. A prior time failure cannot become
PASS through resume.

## Automated stages and scheduling

The policy defines these stages:

- static syntax, documentation, suite inventory, and policy ratchets;
- gate self-contracts;
- coverage-enabled Swift tests and automatic quality metrics;
- development app build and verification;
- packaged-app UI integration;
- isolated Codex and Claude provider integrations;
- distribution and bundled runtime contracts;
- release and publish preflights;
- release-impact and release-workflow contracts;
- the zero-work release time-budget postflight.

Every executable stage has a policy-owned process deadline. The GitHub workflow
has a ten-minute deadline and cancels superseded work. The pull request feedback
SLO is less than ten minutes.

Static validation runs before the parallel self-contract workers. This keeps
its two-second local signal free of scheduler contention. Coverage compilation
and the app build then get exclusive SwiftPM access. Quality analysis reads the
completed Swift log and coverage profile without another test run. Provider
lanes run after the verified app exists. Independent distribution and release
lanes overlap after provider work drains.

Swift and Clang caches stay under `app/.build`. The packaged UI test uses a
stripped process-private app, fake CLI, and private state. Provider tests use
private state and socket roots plus the newly bundled `tmux` and
`detach-state`. Tests do not use installed product state or ambient helpers.

There are no quarantined tests. A future quarantine needs an owner, reason, and
expiry. It cannot remove release evidence.

## Impact and user journeys

The policy maps each path to one test domain, release impact, owning spec, and
one or more user capabilities. Capabilities map to stable user journeys,
requirements, and automated scenarios. A known mixed diff uses the union of
its routes. Deletions use the old path. Renames and copies use both paths. An
unknown path selects every functional stage and every release impact.

| Change | Local diagnostic plan |
| --- | --- |
| Documentation | static |
| Quality policy or CI | static and gate self-contracts |
| Swift source | Swift, metrics, app, packaged UI, and required dependencies |
| CLI or session lifecycle | app, both providers, distribution, runtime, and dependencies |
| Install or distribution | app, distribution, runtime, and dependencies |
| Release or publication | app, preflights, workflow contracts, and dependencies |
| Unknown path | full repository plan |

Hosted pull request CI does not trust the local selection as merge evidence. It
runs the full functional plan exactly once on the merge commit.

## Automatic quality facts

CI downloads the exact evidence from the last successful `main` run before it
starts. An authoritative run accepts only a digest-bound
`quality-metrics.json` from `ci-main`. It never reads a manual floor file.

The metric artifact records exact UI and business test identities, aggregate
line coverage, critical-source coverage, and changed executable Swift lines.
CI rejects a removed test or a lower aggregate or critical-source ratio.
Changed executable lines need at least 90 percent coverage. A new critical
source needs 100 percent coverage for its first baseline. Missing, stale,
unbound, unsafe, or malformed baseline evidence fails closed.

A weekly and manual workflow runs each deterministic safety mutant in a
separate bounded macOS job. The required mutation score is 100 percent. A
survivor, timeout, or infrastructure-like failure is not a kill and fails the
workflow.

## Dashboard

The dashboard generator validates the current manifest, summary, metric and
mutation digests. It shows authority, result, exact commit, exact CI run,
freshness, fingerprint, durations, coverage, affected journeys, scenario gaps,
mutation score, and recent latency.

The same artifact opens locally and deploys to GitHub Pages. Pages deploys only
after a green `ci-main` gate or a green mutation score for that policy. The
workflow does not publish pull request or local evidence.

## Definition of done

An ordinary change is ready only when it has regression evidence, the current
pull request merge commit has an authoritative `quality-gates` PASS, affected
public docs and durable specs match the behavior, and `git diff --check` is
clean. A narrow test or stage rerun is diagnostic only.

The active `main` ruleset has no bypass actor. It requires the current
`quality-gates` check. A pull request or administrator push cannot update
`main` when the check is missing, pending, failed, or stale.

Release readiness also requires the tracked reference-Mac time budgets and the
release-only gates below. Ordinary implementation must not run them.

## Release-only gates

The release workflow automates signing and notarization. A person supplies only
the irreversible publication confirmation and physical evidence that CI cannot
produce.

1. Owner confirmation before irreversible publication.
2. Developer ID signing and Apple notarization with owner-held credentials.
3. The signed real-power smoke test when release impact selects it.
4. The supervised closed-lid probe when release impact selects it.

They remain fail closed. Pull request jobs and ordinary agents do not receive
their credentials and cannot report them as executed.
