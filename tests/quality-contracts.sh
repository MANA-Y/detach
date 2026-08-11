#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
APP_ROOT="$ROOT/app"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-contracts.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

build_path="$(cd -P "$APP_ROOT" && swift build --show-bin-path)"
test_binary="$build_path/DetachAppPackageTests.xctest/Contents/MacOS/DetachAppPackageTests"
profdata="$build_path/codecov/default.profdata"
[ -f "$test_binary" ] && [ ! -L "$test_binary" ] && \
  [ -f "$profdata" ] && [ ! -L "$profdata" ] || {
  printf 'quality contracts: run the coverage-enabled Swift stage first\n' >&2
  exit 1
}

if [ -n "${DETACH_SWIFT_TEST_LOG:-}" ]; then
  [ -f "$DETACH_SWIFT_TEST_LOG" ] && [ ! -L "$DETACH_SWIFT_TEST_LOG" ] || {
    printf 'quality contracts: Swift test log is missing or unsafe\n' >&2
    exit 1
  }
  tests="$DETACH_SWIFT_TEST_LOG"
else
  tests="$TMP_ROOT/tests.txt"
  (
    cd -P "$APP_ROOT"
    mkdir -p .build/quality-codecov
    LLVM_PROFILE_FILE="$APP_ROOT/.build/quality-codecov/list-%p-%m.profraw" \
      swift test list --skip-build --disable-sandbox
  ) >"$tests"
fi

source_commit="${DETACH_QUALITY_SOURCE_COMMIT:-$(git -C "$ROOT" rev-parse HEAD)}"
authority="${DETACH_QUALITY_AUTHORITY:-local-diagnostic}"
output="${DETACH_QUALITY_METRICS_OUTPUT:-$ROOT/app/build/quality-metrics/quality-metrics.json}"
arguments=(
  evaluate
  --test-binary "$test_binary"
  --profile "$profdata"
  --tests "$tests"
  --output "$output"
  --source-commit "$source_commit"
  --authority "$authority"
)
[ -z "${RESOLVED_BASE:-}" ] || arguments+=(--base-commit "$RESOLVED_BASE")
[ -z "${DETACH_QUALITY_BASELINE_ROOT:-}" ] || \
  arguments+=(--baseline-root "$DETACH_QUALITY_BASELINE_ROOT")
[ "${DETACH_QUALITY_ALLOW_POLICY_13_BOOTSTRAP:-0}" != 1 ] || \
  arguments+=(--allow-policy-13-bootstrap)

"$ROOT/scripts/quality-metrics" "${arguments[@]}"
