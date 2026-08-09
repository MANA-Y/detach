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
- Invoking `scripts/release-version X.Y.Z` authorizes its automated commit,
  tag, and publication steps. Push the release commit first to its unique
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
- Developer ID signing, notarization, and the real signed power smoke are
  mandatory for every release. `scripts/release-impact` compares the last
  published tag with the release source. It selects the clean-account/system UI
  matrix only for install, onboarding, approval, update, entitlement, or
  localization impact. It selects supervised closed-lid testing only for
  power, helper, watchdog, lease, assertion, or lid-probe impact. An unknown
  product path selects both manual gates. Test-only, documentation-only, and
  known unrelated product paths do not select them.
- A selected closed-lid probe must emit its first liveness sample within a
  bounded ten-second launch window before owner confirmation is accepted.
  Automated release tests cover failed install and update paths. A selected
  clean-account/system UI matrix uses the short checklist in `docs/testing.md`
  and does not repeat the signed power or lid gates.
- The release entry point supplies the low-level publication confirmation after
  all selected gates pass. After upload, every remote asset is downloaded and
  its digest is independently matched. Missing, extra, changed, or mismatched
  assets fail closed.
- Reference-machine timing budgets are mandatory by default. When the release
  Mac is intentionally busy, the owner may set
  `DETACH_RELEASE_IGNORE_TIMING=1` for one `release-version` invocation and
  confirm the exact `owner/repository@tag`; this omits only wall and per-stage
  timing enforcement. Every functional, artifact, signing, power, lid, and
  publication gate remains mandatory, and the waiver is recorded in private
  gate and workflow evidence.
- Resume state is private under `app/build/`. Resume is allowed only when
  source, durable stage evidence, and existing asset digests still match.
- A resume after the artifact stage requires only credentials for the remaining
  publication work. If artifact validation requires a rebuild, the workflow
  requires the Developer ID, notarization, and Sparkle credentials again.
- After the atomic main/tag push, a paused release can resume from a newer
  synchronized `main` only when the release commit remains an ancestor and all
  later paths are release tooling, release tests, or release documentation.
  The annotated tag and artifact manifest stay bound to the release commit.
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
