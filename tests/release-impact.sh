#!/bin/bash

set -euo pipefail
set +x

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-release-impact.XXXXXX")"
REPO="$TMP_ROOT/repo"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

mkdir -p "$REPO/scripts" "$REPO/quality" "$REPO/tools"
cp "$ROOT/scripts/release-impact" "$REPO/scripts/release-impact"
cp "$ROOT/scripts/quality-policy" "$REPO/scripts/quality-policy"
cp "$ROOT/tools/quality_policy.py" "$REPO/tools/quality_policy.py"
cp "$ROOT/quality/policy.tsv" "$REPO/quality/policy.tsv"
chmod 0755 "$REPO/scripts/release-impact"
chmod 0755 "$REPO/scripts/quality-policy"
git -C "$REPO" init -q
git -C "$REPO" checkout -qb main
git -C "$REPO" config user.name 'Detach Tests'
git -C "$REPO" config user.email 'detach-tests@example.invalid'
printf '%s\n' baseline >"$REPO/README.md"
printf '%s\n' 'app/build/' >"$REPO/.gitignore"
git -C "$REPO" add .gitignore README.md quality/policy.tsv \
  scripts/quality-policy scripts/release-impact tools/quality_policy.py
git -C "$REPO" commit -qm baseline

commit_path() {
  local path="$1" value="$2"
  mkdir -p "$(dirname "$REPO/$path")"
  printf '%s\n' "$value" >"$REPO/$path"
  git -C "$REPO" add "$path"
  git -C "$REPO" commit -qm "$value"
  git -C "$REPO" rev-parse HEAD
}

assert_value() {
  local output="$1" key="$2" expected="$3" actual count
  count="$(awk -F '\t' -v wanted="$key" '$1 == wanted {count++} END {print count+0}' "$output")"
  [ "$count" -eq 1 ] || {
    printf 'release impact key count mismatch: %s (%s)\n' "$key" "$count" >&2
    exit 1
  }
  actual="$(awk -F '\t' -v wanted="$key" '$1 == wanted {print $2; exit}' "$output")"
  [ "$actual" = "$expected" ] || {
    printf 'release impact mismatch: %s=%s, expected %s\n' "$key" "$actual" "$expected" >&2
    exit 1
  }
}

BASE="$(git -C "$REPO" rev-parse HEAD)"
SAFE_HEAD="$(commit_path app/Sources/DetachKit/TerminalLauncher.swift terminal)"
"$REPO/scripts/release-impact" "$BASE" "$SAFE_HEAD" >"$TMP_ROOT/safe.tsv"
assert_value "$TMP_ROOT/safe.tsv" schema 2
assert_value "$TMP_ROOT/safe.tsv" lid_test_required false
assert_value "$TMP_ROOT/safe.tsv" unknown_impact false
! grep -F 'install_matrix' "$TMP_ROOT/safe.tsv" >/dev/null

MATRIX_HEAD="$(commit_path app/Sources/DetachApp/OnboardingView.swift onboarding)"
"$REPO/scripts/release-impact" "$SAFE_HEAD" "$MATRIX_HEAD" >"$TMP_ROOT/matrix.tsv"
assert_value "$TMP_ROOT/matrix.tsv" lid_test_required false
assert_value "$TMP_ROOT/matrix.tsv" unknown_impact false

DMG_HEAD="$(commit_path app/scripts/make-dmg.sh dmg)"
"$REPO/scripts/release-impact" "$MATRIX_HEAD" "$DMG_HEAD" >"$TMP_ROOT/dmg.tsv"
assert_value "$TMP_ROOT/dmg.tsv" lid_test_required false
assert_value "$TMP_ROOT/dmg.tsv" unknown_impact false

CORE_HEAD="$(commit_path bin/detach-core core)"
"$REPO/scripts/release-impact" "$DMG_HEAD" "$CORE_HEAD" >"$TMP_ROOT/core.tsv"
assert_value "$TMP_ROOT/core.tsv" lid_test_required true
assert_value "$TMP_ROOT/core.tsv" unknown_impact false

SHARED_POWER_HEAD="$(commit_path app/Sources/DetachKit/BoundedProcessRunner.swift runner)"
"$REPO/scripts/release-impact" "$CORE_HEAD" "$SHARED_POWER_HEAD" \
  >"$TMP_ROOT/shared-power.tsv"
assert_value "$TMP_ROOT/shared-power.tsv" lid_test_required true
assert_value "$TMP_ROOT/shared-power.tsv" unknown_impact false

REVIEW_ROOT="$REPO/app/build/release-impact-reviews"
REVIEW="$REVIEW_ROOT/current.tsv"
mkdir -m 0700 -p "$REVIEW_ROOT"
cat >"$REVIEW" <<EOF
schema	2
base_commit	$CORE_HEAD
head_commit	$SHARED_POWER_HEAD
lid_test_required	false
lid_test_rationale	No assertion, lease, helper daemon, or closed-lid runtime behavior changed.
EOF
chmod 0600 "$REVIEW"
DETACH_RELEASE_IMPACT_REVIEW="$REVIEW" \
  "$REPO/scripts/release-impact" "$CORE_HEAD" "$SHARED_POWER_HEAD" \
  >"$TMP_ROOT/reviewed.tsv"
assert_value "$TMP_ROOT/reviewed.tsv" lid_test_required false
assert_value "$TMP_ROOT/reviewed.tsv" unknown_impact false
assert_value "$TMP_ROOT/reviewed.tsv" semantic_review_applied true
grep -F $'lid_test_review_reason\tNo assertion, lease' \
  "$TMP_ROOT/reviewed.tsv" >/dev/null

chmod 0644 "$REVIEW"
if DETACH_RELEASE_IMPACT_REVIEW="$REVIEW" \
    "$REPO/scripts/release-impact" "$CORE_HEAD" "$SHARED_POWER_HEAD" \
    >"$TMP_ROOT/review-mode.out" 2>"$TMP_ROOT/review-mode.err"; then
  printf 'release impact accepted a public impact review\n' >&2
  exit 1
fi
grep -F 'must not be accessible by group/other' \
  "$TMP_ROOT/review-mode.err" >/dev/null
chmod 0600 "$REVIEW"

if DETACH_RELEASE_IMPACT_REVIEW="$REVIEW" \
    "$REPO/scripts/release-impact" "$BASE" "$SHARED_POWER_HEAD" \
    >"$TMP_ROOT/review-range.out" 2>"$TMP_ROOT/review-range.err"; then
  printf 'release impact accepted a stale impact review\n' >&2
  exit 1
fi
grep -F 'does not match the exact release source range' \
  "$TMP_ROOT/review-range.err" >/dev/null

POWER_HEAD="$(commit_path app/Sources/DetachPower/main.swift power)"
"$REPO/scripts/release-impact" "$SHARED_POWER_HEAD" "$POWER_HEAD" \
  >"$TMP_ROOT/power.tsv"
assert_value "$TMP_ROOT/power.tsv" lid_test_required true
assert_value "$TMP_ROOT/power.tsv" unknown_impact false

UNKNOWN_HEAD="$(commit_path product/new-runtime future)"
"$REPO/scripts/release-impact" "$POWER_HEAD" "$UNKNOWN_HEAD" >"$TMP_ROOT/unknown.tsv"
assert_value "$TMP_ROOT/unknown.tsv" lid_test_required true
assert_value "$TMP_ROOT/unknown.tsv" unknown_impact true
grep -F $'unknown_reason\tproduct/new-runtime' "$TMP_ROOT/unknown.tsv" >/dev/null

cat >"$REVIEW" <<EOF
schema	2
base_commit	$POWER_HEAD
head_commit	$UNKNOWN_HEAD
lid_test_required	false
lid_test_rationale	A semantic review cannot narrow an unknown product path impact selection.
EOF
chmod 0600 "$REVIEW"
if DETACH_RELEASE_IMPACT_REVIEW="$REVIEW" \
    "$REPO/scripts/release-impact" "$POWER_HEAD" "$UNKNOWN_HEAD" \
    >"$TMP_ROOT/review-unknown.out" 2>"$TMP_ROOT/review-unknown.err"; then
  printf 'release impact review omitted gates for an unknown product path\n' >&2
  exit 1
fi
grep -F 'cannot omit a gate selected by an unknown product path' \
  "$TMP_ROOT/review-unknown.err" >/dev/null

NEW_APP_HEAD="$(commit_path app/Sources/DetachApp/FutureFlow.swift future-app)"
"$REPO/scripts/release-impact" "$UNKNOWN_HEAD" "$NEW_APP_HEAD" \
  >"$TMP_ROOT/new-app.tsv"
assert_value "$TMP_ROOT/new-app.tsv" lid_test_required true
assert_value "$TMP_ROOT/new-app.tsv" unknown_impact true
grep -F $'unknown_reason\tapp/Sources/DetachApp/FutureFlow.swift' \
  "$TMP_ROOT/new-app.tsv" >/dev/null

git -C "$REPO" checkout -qb unrelated "$BASE"
UNRELATED_HEAD="$(commit_path docs/note.md unrelated)"
if "$REPO/scripts/release-impact" "$NEW_APP_HEAD" "$UNRELATED_HEAD" \
    >"$TMP_ROOT/non-ancestor.out" 2>"$TMP_ROOT/non-ancestor.err"; then
  printf 'release impact accepted a non-ancestor base\n' >&2
  exit 1
fi
grep -F 'base must be an ancestor of head' "$TMP_ROOT/non-ancestor.err" >/dev/null

printf 'Release impact tests passed\n'
