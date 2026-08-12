#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-history-contract.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

write_run() {
  local name="$1" result="$2" wall="$3" static_status="$4" static_duration="$5" finished="$6"
  local run="$TMP_ROOT/$name" summary_digest
  mkdir -p "$run"
  printf 'policy\tmode\tstage\tstatus\tduration_seconds\tlog\tlog_sha256\torigin_run\n' \
    >"$run/summary.tsv"
  printf '23\trepository\tstatic\t%s\t%s\tstatic.log\t%s\t-\n' \
    "$static_status" "$static_duration" "$(printf digest | shasum -a 256 | awk '{print $1}')" \
    >>"$run/summary.tsv"
  summary_digest="$(shasum -a 256 "$run/summary.tsv" | awk '{print $1}')"
  cat >"$run/manifest.tsv" <<EOF
schema	4
policy	23
mode	repository
authority	ci-main
source_commit	0123456789abcdef0123456789abcdef01234567
fingerprint	0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
stages	static
specs	documentation
capabilities	quality-system
journeys	J-QUALITY-CHANGE
started_at	2026-08-12T10:00:00Z
finished_at	$finished
duration_seconds	$wall
timing_wall_seconds	$wall
summary_sha256	$summary_digest
result	$result
EOF
}

write_run one passed 100 passed 1 2026-08-12T10:00:01Z
write_run two failed 180 environment-failed 3 2026-08-12T10:00:02Z
write_run three passed 120 passed 2 2026-08-12T10:00:03Z
awk -F '\t' '$1 != "specs" {print}' "$TMP_ROOT/three/manifest.tsv" \
  >"$TMP_ROOT/three/manifest-without-dashboard-fields.tsv"
mv "$TMP_ROOT/three/manifest-without-dashboard-fields.tsv" \
  "$TMP_ROOT/three/manifest.tsv"
mkdir -p "$TMP_ROOT/unsupported"
printf 'schema\t3\nresult\tpassed\n' >"$TMP_ROOT/unsupported/manifest.tsv"

"$ROOT/scripts/quality-history" "$TMP_ROOT" >"$TMP_ROOT/unsupported-report.tsv"
grep -F $'runs\t3' "$TMP_ROOT/unsupported-report.tsv" >/dev/null
grep -F $'invalid_evidence\t0' "$TMP_ROOT/unsupported-report.tsv" >/dev/null

mkdir -p "$TMP_ROOT/invalid-current"
printf 'schema\t4\nresult\tpassed\n' >"$TMP_ROOT/invalid-current/manifest.tsv"
mkdir -p "$TMP_ROOT/invalid-encoding"
printf '\377' >"$TMP_ROOT/invalid-encoding/manifest.tsv"

"$ROOT/scripts/quality-history" "$TMP_ROOT" >"$TMP_ROOT/report.tsv"
grep -F $'runs\t3' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'passed\t2' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'invalid_evidence\t2' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'latest_result\tpassed' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'latest_environment_failure\tfalse' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'wall_p50_seconds\t120' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'wall_p95_seconds\t180' "$TMP_ROOT/report.tsv" >/dev/null
grep -F $'static\t3\t1\t1\t2\t3' "$TMP_ROOT/report.tsv" >/dev/null
"$ROOT/scripts/quality-history" --format json "$TMP_ROOT" \
  | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["schema"] == 2 and value["runs"] == 3 and value["latest"] == {"environment_failure": False, "result": "passed"}'

printf 'Quality history contract tests passed\n'
