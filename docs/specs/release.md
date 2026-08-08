# Release and distribution specification

## Outcome

A Detach release is an independently verified, Apple Silicon-only app and
immutable CLI payload. Ordinary development must never create tags, notarize,
change real power state, upload assets, or claim publication.

## Invariants

- `scripts/release-version X.Y.Z` is the only normal release entry point.
  The lower-level release and publication scripts are implementation details.
- Release starts from clean, synchronized `main`. The tracked `BUILD`
  must match the latest published manifest; `VERSION` and `BUILD`
  change together in one release commit.
- After exact owner confirmation, push the release commit to its unique
  `detach-release/vX.Y.Z` ref. The commit must pass the official GitHub Actions
  `quality-gates` job. Then make sure that remote `main` did not change.
  Atomically push the approved commit and annotated tag. Verify both refs and
  remove only the matching temporary ref. No actor has a general `main`
  ruleset bypass.
- The app, watchdog, bundled tmux, state helper, power client, root helper, and
  Sparkle executables contain only `arm64`. Intel Macs are unsupported.
- The pinned tmux source build may reuse only an arm64 product keyed by the
  builder, source checksums, SDK, compiler, and deployment target; every copied
  cache product passes the normal architecture and linkage validation.
- The immutable payload order is `detach`, `detach-core`,
  `detach-install`, `detach-state`, `detach-power`, `tmux`.
  Installation activates a content-addressed version atomically.
- Developer ID signing, notarization, real signed power smoke, and supervised
  closed-lid testing are mandatory release gates and are never inferred from
  unit tests. The protected lid probe must emit its first liveness sample within
  a bounded ten-second launch window before owner confirmation is accepted.
- Automated release tests cover failed install and update paths. After the
  signed artifacts exist, the owner must complete the short clean-account or VM
  checklist in `docs/testing.md`. The workflow requires exact
  `owner/repository@tag` confirmation before it installs the local candidate or
  starts the signed power and lid gates. This checklist does not repeat those
  hardware gates.
- Publication requires exact `owner/repository@tag` confirmation. After
  upload, every remote asset is downloaded and its digest independently
  matched. Missing, extra, changed, or mismatched assets fail closed.
- Reference-machine timing budgets are mandatory by default. When the release
  Mac is intentionally busy, the owner may set
  `DETACH_RELEASE_IGNORE_TIMING=1` for one `release-version` invocation and
  confirm the exact `owner/repository@tag`; this omits only wall and per-stage
  timing enforcement. Every functional, artifact, signing, power, lid, and
  publication gate remains mandatory, and the waiver is recorded in private
  gate and workflow evidence.
- Resume state is private under `app/build/`. Resume is allowed only when
  source, durable stage evidence, and existing asset digests still match.
- Sparkle remains pinned and signed inside-out. Production builds never carry
  the development library-validation exception. Appcasts contain exactly one
  arm64 hardware requirement.
- Distribution bootstrap runs only from `/Applications`, never a DMG or
  App Translocation path. A Sparkle update replaces the app; bootstrap switches
  the CLI payload without rewriting binaries used by live sessions. A failed
  download, archive, signature, app installation, CLI synchronization, or
  helper replacement keeps the prior app or CLI control path usable and
  provides a Repair path.

## Owned paths

`scripts/release-version`, `scripts/release-lid-probe`,
`app/scripts/release.sh`, `app/scripts/publish-release.sh`,
`app/scripts/make-dmg.sh`, `app/scripts/verify-appcast.sh`,
`VERSION`, `BUILD`, release/publish workflow tests, and release CI.

## Fast feedback

Run the narrow hermetic script matching the edit:
`tests/release-preflight.sh`, `tests/publish-preflight.sh`, or
`tests/release-workflow.sh`. These never replace the impact-selected
quality gate or the manual release-only gates listed in `docs/testing.md`.
