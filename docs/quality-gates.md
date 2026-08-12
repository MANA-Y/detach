# Quality gates

`quality/policy.tsv` is the single quality policy. It owns path impact,
capabilities, user journeys, requirements, stages, time limits, critical
sources, and release impact. `scripts/quality-policy` validates this source and
generates `quality/generated/policy.json` and
`quality/generated/spec-traceability.md`. The policy contains only current
state. Git stores its history. Generated data must match the source.

`scripts/quality-gate` applies the policy. Local runs are diagnostics. Hosted
pull request CI runs every functional stage on the current merge commit and is
the only ordinary merge authority. Unknown paths select the full plan.
For a normal local change, `gate-contract` runs direct self-contracts only.
`--mode repository` runs the full orchestrator shards. An explicit local
`--stage gate-contract` also runs all shards for diagnosis.

## Commands

- `scripts/quality-gate --plan --explain` shows affected capabilities,
  specifications, journeys, stages, and the path that selected each stage.
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
- `scripts/quality-scenarios rerun SC-ID` runs the owning diagnostic stage for
  an instrumented scenario, or its direct policy command otherwise. The owning
  stage process deadline bounds both forms. The helper has 30 seconds for
  evidence finalization and process-group cleanup.
- `scripts/quality-history [--format tsv|json] [RESULT_ROOT]` validates retained
  current-schema summaries and reports run and failure counts plus p50 and p95
  wall and stage durations. A declared unsupported schema is outside the
  sample. Current-schema timing can span earlier policy identifiers and does
  not require dashboard-only manifest fields. Malformed telemetry evidence
  stays invalid. The tool cannot produce readiness evidence or decode an old
  layout.
- `scripts/quality-care validate` checks the versioned workflow eval corpus.
  `scripts/quality-care evaluate` grades diff impact and private-scope cases.
  `scripts/quality-care assess` compares the results with retained run latency.
  `scripts/quality-care latest --optional` inspects at most five completed
  runs within one 60-second deadline. It restores the newest valid
  current-policy care artifact for a dashboard deploy.
- `scripts/quality-policy specs` lists current durable specs.
  `scripts/quality-policy render-specs` prints their requirement, journey, and
  scenario links.
- `scripts/quality-dashboard generate` writes deterministic static HTML and
  JSON. `scripts/quality-dashboard serve` binds to loopback and stops after its
  deadline.
- `scripts/quality-mutation` validates and runs the deterministic safety mutant
  corpus. Mutation work does not add to pull request latency.
- `scripts/quality-promote` binds a successful pull-request artifact to its
  final `main` merge commit. It runs only in the hosted main-push workflow.

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

An ordinary main merge keeps the original `ci-merge` manifest immutable. A
separate promotion record supplies `ci-main` authority only when GitHub and Git
facts prove that the tested synthetic merge and final merge have the same tree
and ordered parents. The dashboard shows both commits and the source run. The
next metrics comparison uses the final main commit. A direct or ambiguous main
push runs the complete repository gate instead.

The repository gate writes private evidence under
`app/build/quality-gates/`. One run contains a schema-versioned TSV summary,
gate and scenario JUnit, scenario JSONL, Markdown, stage logs, safe environment
facts, a provenance manifest, and a digest inventory. Coverage runs also
contain `quality-metrics.json`. A failed scenario adds a bounded
`repair-bundle.json` with its requirement and journey links, exact rerun, and
at most the last 100 log lines.

The manifest binds the evidence to the policy, authority, source and base
commits, exact input and plan fingerprints, selected capabilities, journeys,
owning specifications, stages, timestamps, inherited timing, parent evidence,
environment, artifacts, summary, and every stage log. A failure, timeout,
interruption, blocked
dependency, unsafe file, malformed record, or digest mismatch cannot produce
PASS. Failure output gives the exact diagnostic rerun.

An instrumented scenario writes one begin event and one pass event. Missing,
duplicate, reordered, unknown, or cross-stage events fail closed. Legacy stage
records remain explicit until the owning suite gets markers. Planned scenario
records remain visible gaps. Only the supervised closed-lid release gate is
manual because it needs physical evidence.

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
completed Swift log and coverage profile without another test run. The short
packaged UI lane runs after the verified app and before the CPU-intensive
provider, runtime, and gate-contract lanes. This prevents WindowServer event
delivery from competing with those workers. Provider lanes then run in
parallel. After they drain, the runtime and gate-contract lanes run in
parallel. This admits at most two process-heavy top-level lanes. Independent
distribution and release lanes overlap after both groups drain.

The gate-contract stage keeps lightweight contracts concurrent. It admits at
most two process-heavy orchestrator shards at one time. This limit prevents
process oversubscription without increasing the stage budget.

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

## Continuous care

`quality/evals.json` contains stable expected outcomes for representative
historical tasks, escaped defects, policy mutations, and repository-scope
violations. Impact cases assert the complete stage, specification, capability,
user-journey, and release-gate plan after dependency closure. Scope cases assert
that internal presentations, work plans, and credential paths stay ignored.

The quality-care workflow has a five-minute deadline. It reads up to 10 gate
artifacts from the last 13 days. Each download has a 20-second deadline. A
missing artifact fails the care run. The workflow creates one open issue for
an eval regression, invalid evidence, an unresolved latest gate result, or wall p95 at
or above 480 seconds. Repaired failures remain in run and stage telemetry. The
documentation-care workflow has the same overall
deadline. It can create one repair pull request only when deterministic
generated policy views drift. Both workflows cancel superseded runs and never
run release tools.

## Dashboard

The dashboard generator validates the current manifest, summary, metric and
mutation digests. It also validates the care policy, source commit, schema, and
input digests. It shows authority, result, exact commit, exact CI run,
freshness, fingerprint, durations, coverage, affected journeys, scenario gaps,
mutation score, workflow evals, feedback p95 and SLO, security state, and recent
latency. Code review stays a read-only step in the active agent workflow. It is
not a repository gate or a second merge authority.

The same artifact opens locally and deploys to GitHub Pages. Main and mutation
workflows deploy only after a green `ci-main` gate or a green mutation score for
that policy. The bounded care workflow can publish a validated attention
result, then marks its run failed and opens one issue. A later deploy restores
the newest valid care artifact for the current policy. The next healthy care
run closes the issue. No workflow publishes pull request or local gate
evidence.

## Definition of done

An ordinary change is ready only when it has regression evidence, the current
pull request merge commit has an authoritative `quality-gates` PASS, affected
public docs and durable specs match the behavior, and `git diff --check` is
clean. A narrow test or stage rerun is diagnostic only.

The active `main` ruleset has no bypass actor. It requires a pull request, one
current strict `quality-gates` check from GitHub Actions, and a merge commit. It
requires zero approving reviews. It also rejects branch deletion and
non-fast-forward updates. A pull request or administrator push cannot update
`main` when the check is missing, pending, failed, or stale.

After a pull request opens, run:

```text
scripts/quality-merge --repository OWNER/REPOSITORY \
  --pull-request NUMBER --head HEAD_SHA --repair-attempt ATTEMPT
```

The command waits no longer than `pr_feedback_seconds` for the authoritative
check. It enables native auto-merge only for `HEAD_SHA`, then waits no longer
than `merge_wait_seconds`. It disables auto-merge on timeout. The command
rejects a changed head, a weaker ruleset, and an attempt above
`max_repair_loops`. Its JSON evidence is current-policy state under
`app/build/`; Git remains the history.

## Security care

Dependabot checks immutable GitHub Actions pins and Swift package pins each
week. It groups each ecosystem into at most one open update pull request. This
keeps update traffic from exhausting the pull-request feedback queue. The
bounded security workflow scans both GitHub Actions source and arm64 Swift
source with CodeQL after a `main` change and on a weekly schedule. The Swift
scan restores the existing quality-gate dependency graph, resolves the tracked
lock before tracing, and removes cached products. Three parallel jobs analyze
`DetachKit`, `DetachApp`, and the process entry points. The app and process jobs
build `DetachKit` before CodeQL starts, so each repository source is traced in
one scope. Traced builds disable Swift compiler batch mode. CodeQL gets one
bounded extractor task for each primary source file instead of one large module
batch. Each job keeps the 15-minute deadline. Build concurrency matches the
three-thread extractor, and unused index data is disabled. Dependency network,
version work, one large compiler extraction, and process oversubscription cannot
consume the complete security workflow budget. These care jobs do not extend
pull-request feedback and cannot run release commands.

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
