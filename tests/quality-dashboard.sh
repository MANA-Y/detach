#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-dashboard.XXXXXX")"
RESULT_ROOT="$TMP_ROOT/results"
RUN_DIR="$RESULT_ROOT/20260811T100000Z-1"
OUTPUT="$TMP_ROOT/dashboard"
MUTATION_SUMMARY="$TMP_ROOT/mutation-summary.json"
POLICY_VERSION="$("$ROOT/scripts/quality-policy" version)"
trap 'rm -rf "$TMP_ROOT"' EXIT HUP INT TERM

fail() {
  printf 'quality-dashboard-contract: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$RUN_DIR"
printf 'policy\tmode\tstage\tstatus\tduration_seconds\tlog\tlog_sha256\torigin_run\n' \
  >"$RUN_DIR/summary.tsv"
for record in \
  'static passed 2' \
  'swift passed 8' \
  'quality-contracts passed 3' \
  'app passed 12' \
  'ui-e2e passed 4' \
  'release-budget passed 0'; do
  read -r stage status duration <<<"$record"
  printf '%s\trepository\t%s\t%s\t%s\t%s.log\tdigest\t-\n' \
    "$POLICY_VERSION" "$stage" "$status" "$duration" "$stage" \
    >>"$RUN_DIR/summary.tsv"
done
summary_digest="$(shasum -a 256 "$RUN_DIR/summary.tsv" | awk '{print $1}')"
cat >"$RUN_DIR/quality-metrics.json" <<JSON
{
  "changed_lines": {
    "base_commit": "fedcba9876543210fedcba9876543210fedcba98",
    "files": [{"covered": 9, "executable": 10, "path": "app/Sources/DetachApp/RootView.swift"}],
    "line_coverage": {"covered": 9, "percent": 90.0, "total": 10},
    "minimum_percent": 90,
    "status": "passed"
  },
  "comparison": {
    "baseline_policy": $POLICY_VERSION,
    "baseline_source_commit": "fedcba9876543210fedcba9876543210fedcba98",
    "mode": "green-main-artifact",
    "regressions": [],
    "status": "passed"
  },
  "critical_files": [],
  "policy": $POLICY_VERSION,
  "schema": 1,
  "source_commit": "0123456789abcdef0123456789abcdef01234567",
  "suites": {
    "business": {
      "line_coverage": {"covered": 95, "percent": 95.0, "total": 100},
      "test_count": 1,
      "tests": ["DetachKitTests.Sample/testOne"]
    },
    "ui": {
      "line_coverage": {"covered": 30, "percent": 30.0, "total": 100},
      "test_count": 1,
      "tests": ["DetachAppTests.Sample/testOne"]
    }
  }
}
JSON
metrics_digest="$(shasum -a 256 "$RUN_DIR/quality-metrics.json" | awk '{print $1}')"
printf 'schema\t1\nfile\tquality-metrics.json\t%s\n' "$metrics_digest" \
  >"$RUN_DIR/artifacts.tsv"
artifacts_digest="$(shasum -a 256 "$RUN_DIR/artifacts.tsv" | awk '{print $1}')"
cat >"$RUN_DIR/manifest.tsv" <<EOF
schema	4
policy	$POLICY_VERSION
mode	repository
authority	ci-merge
source_commit	0123456789abcdef0123456789abcdef01234567
base_commit	fedcba9876543210fedcba9876543210fedcba98
input_fingerprint	0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
fingerprint	abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
stages	static,swift,quality-contracts,app,ui-e2e,release-budget
capabilities	onboarding
journeys	J-ONBOARD-FIRST-RUN,J-ONBOARD-PROVIDER,J-ONBOARD-APPROVAL
started_at	2026-08-11T10:00:00Z
finished_at	2026-08-11T10:00:29Z
duration_seconds	29
timing_wall_seconds	29
resumed_from_run	-
resumed_from_manifest_sha256	-
environment_sha256	0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
artifacts_sha256	$artifacts_digest
summary_sha256	$summary_digest
result	passed
EOF

cat >"$MUTATION_SUMMARY" <<JSON
{
  "floor_percent": 100,
  "killed": 1,
  "policy": $POLICY_VERSION,
  "results": [
    {
      "duration_seconds": 4,
      "exit_code": 1,
      "mutant_id": "foreign-tmux-must-collide",
      "output_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "policy": $POLICY_VERSION,
      "requirement": "QC-HEALTH-FRESHNESS",
      "schema": 1,
      "source": "app/Sources/DetachKit/SessionHealth.swift",
      "status": "killed",
      "test_suite": "DetachKitTests.SessionHealthTests",
      "timeout_seconds": 240
    }
  ],
  "schema": 1,
  "score_percent": 100,
  "status": "passed",
  "total": 1
}
JSON

"$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
  --output "$OUTPUT" --run-url 'https://github.example/actions/runs/1' \
  --mutation-summary "$MUTATION_SUMMARY" >/dev/null
[ -f "$OUTPUT/index.html" ] && [ -f "$OUTPUT/data.json" ] || \
  fail 'dashboard artifacts are missing'
first_html="$(shasum -a 256 "$OUTPUT/index.html" | awk '{print $1}')"
first_data="$(shasum -a 256 "$OUTPUT/data.json" | awk '{print $1}')"
"$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
  --output "$OUTPUT" --run-url 'https://github.example/actions/runs/1' \
  --mutation-summary "$MUTATION_SUMMARY" >/dev/null
[ "$first_html" = "$(shasum -a 256 "$OUTPUT/index.html" | awk '{print $1}')" ] || \
  fail 'HTML generation is not deterministic'
[ "$first_data" = "$(shasum -a 256 "$OUTPUT/data.json" | awk '{print $1}')" ] || \
  fail 'dashboard data generation is not deterministic'

grep -F '<main>' "$OUTPUT/index.html" >/dev/null || fail 'semantic main element is missing'
grep -F 'aria-label="Run summary"' "$OUTPUT/index.html" >/dev/null || \
  fail 'summary accessibility label is missing'
grep -F '@media (max-width:560px)' "$OUTPUT/index.html" >/dev/null || \
  fail 'responsive layout contract is missing'
grep -F 'STALE ·' "$OUTPUT/index.html" >/dev/null || fail 'stale evidence state is missing'
grep -F 'J-ONBOARD-FIRST-RUN' "$OUTPUT/index.html" >/dev/null || \
  fail 'impacted journey is missing'
grep -F 'planned' "$OUTPUT/index.html" >/dev/null || fail 'planned gap is hidden'
grep -F 'changed lines 90.00%' "$OUTPUT/index.html" >/dev/null || \
  fail 'measured changed-line coverage is missing'
grep -F '100% · 1/1 killed · passed' "$OUTPUT/index.html" >/dev/null || \
  fail 'mutation score is missing'
! grep -F '<svg' "$OUTPUT/index.html" >/dev/null || fail 'dashboard contains hand-drawn SVG'

python3 - "$OUTPUT/data.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
assert data["schema"] == 1
assert data["run"]["authority"] == "ci-merge"
assert data["run"]["result"] == "passed"
assert data["quality"]["planned_scenarios"] == 3
assert data["quality"]["coverage"]["comparison"]["mode"] == "green-main-artifact"
assert data["quality"]["mutation"]["score_percent"] == 100
assert [journey["id"] for journey in data["journeys"]] == [
    "J-ONBOARD-FIRST-RUN", "J-ONBOARD-PROVIDER", "J-ONBOARD-APPROVAL"
]
PY

PYTHONDONTWRITEBYTECODE=1 python3 - "$ROOT/tools/quality_dashboard.py" "$OUTPUT" <<'PY'
import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(sys.argv[1]).parent))
spec = importlib.util.spec_from_file_location("quality_dashboard", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class FakeServer:
    server_address = ("127.0.0.1", 43210)
    def __init__(self, address, handler): self.closed = False
    def serve_forever(self): pass
    def shutdown(self): pass
    def server_close(self): self.closed = True

class FakeTimer:
    instance = None
    def __init__(self, seconds, callback):
        self.seconds, self.callback, self.daemon = seconds, callback, False
        self.started = self.cancelled = False
        FakeTimer.instance = self
    def start(self): self.started = True
    def cancel(self): self.cancelled = True

arguments = SimpleNamespace(directory=Path(sys.argv[2]), port=0, seconds=1)
output = io.StringIO()
with patch.object(module, "ThreadingHTTPServer", FakeServer), \
     patch.object(module.threading, "Timer", FakeTimer), redirect_stdout(output):
    assert module.serve(arguments) == 0
assert FakeTimer.instance.seconds == 1
assert FakeTimer.instance.started and FakeTimer.instance.cancelled
assert "stops after 1s" in output.getvalue()
PY

printf 'tamper\n' >>"$RUN_DIR/summary.tsv"
if "$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
    --output "$TMP_ROOT/tampered" >"$TMP_ROOT/tampered.out" 2>&1; then
  fail 'tampered summary was accepted'
fi
grep -F 'summary digest does not match' "$TMP_ROOT/tampered.out" >/dev/null || \
  fail 'tampered summary failure is unclear'

printf 'Quality dashboard contracts passed\n'
