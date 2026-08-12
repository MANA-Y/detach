#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/detach-quality-dashboard.XXXXXX")"
RESULT_ROOT="$TMP_ROOT/results"
RUN_DIR="$RESULT_ROOT/20260811T100000Z-1"
OUTPUT="$TMP_ROOT/dashboard"
PROMOTED_OUTPUT="$TMP_ROOT/promoted-dashboard"
MUTATION_SUMMARY="$TMP_ROOT/mutation-summary.json"
CARE_SUMMARY="$TMP_ROOT/care-summary.json"
CARE_EVALS="$TMP_ROOT/evals.json"
CARE_HISTORY="$TMP_ROOT/history.json"
POLICY_VERSION="$("$ROOT/scripts/quality-policy" version)"
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
MAIN_COMMIT=8989898989898989898989898989898989898989
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
specs	app
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

PRIOR_RUN="$RESULT_ROOT/20260810T100000Z-1"
mkdir -p "$PRIOR_RUN"
awk -F '\t' -v OFS='\t' \
  '$1 == "policy" {$2=21} {print}' \
  "$RUN_DIR/manifest.tsv" >"$PRIOR_RUN/manifest.tsv"

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

printf '{"schema":1,"status":"passed"}\n' >"$CARE_EVALS"
printf '{"schema":1,"runs":4}\n' >"$CARE_HISTORY"
CARE_EVAL_DIGEST="$(shasum -a 256 "$CARE_EVALS" | awk '{print $1}')"
CARE_HISTORY_DIGEST="$(shasum -a 256 "$CARE_HISTORY" | awk '{print $1}')"
cat >"$CARE_SUMMARY" <<JSON
{
  "schema": 3,
  "policy": $POLICY_VERSION,
  "source_commit": "$SOURCE_COMMIT",
  "status": "passed",
  "reasons": [],
  "inputs": {
    "eval_sha256": "$CARE_EVAL_DIGEST",
    "history_sha256": "$CARE_HISTORY_DIGEST"
  },
  "evals": {
    "passed": 8,
    "total": 8,
    "categories": {
      "escaped-defect": 2,
      "historical-task": 2,
      "policy-mutant": 2,
      "scope-violation": 2
    }
  },
  "latency": {
    "status": "healthy",
    "wall_p95_seconds": 285,
    "alert_seconds": 480,
    "slo_seconds": 600
  },
  "runs": {
    "total": 4,
    "failed_or_interrupted": 1,
    "environment_failures": 0,
    "invalid_evidence": 0,
    "unresolved_failure": false
  }
}
JSON

"$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
  --output "$OUTPUT" --run-url 'https://github.example/actions/runs/1' \
  --mutation-summary "$MUTATION_SUMMARY" --care-summary "$CARE_SUMMARY" >/dev/null
[ -f "$OUTPUT/index.html" ] && [ -f "$OUTPUT/data.json" ] || \
  fail 'dashboard artifacts are missing'
first_html="$(shasum -a 256 "$OUTPUT/index.html" | awk '{print $1}')"
first_data="$(shasum -a 256 "$OUTPUT/data.json" | awk '{print $1}')"
"$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
  --output "$OUTPUT" --run-url 'https://github.example/actions/runs/1' \
  --mutation-summary "$MUTATION_SUMMARY" --care-summary "$CARE_SUMMARY" >/dev/null
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
grep -F 'Specifications</span><br>app' "$OUTPUT/index.html" >/dev/null || \
  fail 'impacted specification is missing'
grep -F 'Planned gaps</span><strong>0' "$OUTPUT/index.html" >/dev/null || \
  fail 'closed scenario set still reports a planned gap'
grep -F 'changed lines 90.00%' "$OUTPUT/index.html" >/dev/null || \
  fail 'measured changed-line coverage is missing'
grep -F '100% · 1/1 killed · passed' "$OUTPUT/index.html" >/dev/null || \
  fail 'mutation score is missing'
grep -F '8/8 passed · passed · 1 repaired failure retained · source' "$OUTPUT/index.html" >/dev/null || \
  fail 'workflow-eval summary is missing'
grep -F 'p95 285s · alert 480s · SLO 600s · healthy' "$OUTPUT/index.html" >/dev/null || \
  fail 'feedback latency summary is missing'
! grep -F '<svg' "$OUTPUT/index.html" >/dev/null || fail 'dashboard contains hand-drawn SVG'

python3 - "$OUTPUT/data.json" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
assert data["schema"] == 2
assert data["run"]["authority"] == "ci-merge"
assert data["run"]["result"] == "passed"
assert [spec["id"] for spec in data["specifications"]] == ["app"]
assert data["quality"]["planned_scenarios"] == 0
assert data["quality"]["coverage"]["comparison"]["mode"] == "green-main-artifact"
assert data["quality"]["mutation"]["score_percent"] == 100
assert data["quality"]["merge"] == "not-yet-emitted"
assert data["quality"]["security"] == {
    "cadence": "main-and-weekly",
    "codeql_languages": ["actions", "swift"],
    "pull_request_feedback": "not-selected",
    "status": "configured",
}
assert data["quality"]["care"]["evals"] == {
    "categories": {
        "escaped-defect": 2, "historical-task": 2,
        "policy-mutant": 2, "scope-violation": 2,
    },
    "passed": 8,
    "total": 8,
}
assert len(data["trends"]) == 2
assert [journey["id"] for journey in data["journeys"]] == [
    "J-ONBOARD-FIRST-RUN", "J-ONBOARD-PROVIDER", "J-ONBOARD-APPROVAL"
]

sys.path.insert(0, "tools")
from quality_dashboard import DashboardError, parse_merge_evidence
assert parse_merge_evidence(
    "Merge change\n\nQuality-Policy: %s\nQuality-Repair-Attempt: 1\n" % data["run"]["policy"],
    data["run"]["policy"], 2,
) == {
    "policy": data["run"]["policy"], "repair_attempt": 1,
    "maximum_repair_loops": 2, "status": "passed",
}
try:
    parse_merge_evidence(
        "Quality-Policy: %s\n" % data["run"]["policy"],
        data["run"]["policy"], 2,
    )
except DashboardError:
    pass
else:
    raise AssertionError("dashboard accepted incomplete merge evidence")
PY

manifest_digest="$(shasum -a 256 "$RUN_DIR/manifest.tsv" | awk '{print $1}')"
cat >"$RUN_DIR/promotion.tsv" <<EOF
schema	1
authority	ci-main
result	passed
repository	owner/repository
main_commit	$MAIN_COMMIT
main_tree	eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
base_commit	fedcba9876543210fedcba9876543210fedcba98
head_commit	bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
tested_commit	0123456789abcdef0123456789abcdef01234567
tested_tree	eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
pull_request	25
merged_at	2026-08-11T10:00:30Z
source_run	1
source_run_attempt	1
source_run_url	https://github.com/owner/repository/actions/runs/1
source_artifact	quality-gate-evidence-1-1
source_manifest_sha256	$manifest_digest
EOF
"$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
  --output "$PROMOTED_OUTPUT" \
  --run-url 'https://github.com/owner/repository/actions/runs/2' \
  --mutation-summary "$MUTATION_SUMMARY" --care-summary "$CARE_SUMMARY" >/dev/null
grep -F "Tested merge <code>0123456789abcdef0123456789abcdef01234567</code>" \
  "$PROMOTED_OUTPUT/index.html" >/dev/null || fail 'promotion provenance is missing'
python3 - "$PROMOTED_OUTPUT/data.json" "$MAIN_COMMIT" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
assert data["run"]["authority"] == "ci-main"
assert data["run"]["commit"] == sys.argv[2]
assert data["run"]["tested_commit"] == "0123456789abcdef0123456789abcdef01234567"
assert data["run"]["promotion"]["source_run"] == "1"
assert len(data["trends"]) == 2
PY

cp "$RUN_DIR/promotion.tsv" "$TMP_ROOT/promotion.tsv"
sed 's/^tested_tree.*/tested_tree\t0000000000000000000000000000000000000000/' \
  "$TMP_ROOT/promotion.tsv" >"$RUN_DIR/promotion.tsv"
if "$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
    --output "$TMP_ROOT/tampered-promotion" \
    >"$TMP_ROOT/tampered-promotion.out" 2>&1; then
  fail 'tampered promotion evidence was accepted'
fi
grep -F 'promotion evidence does not bind' \
  "$TMP_ROOT/tampered-promotion.out" >/dev/null || \
  fail 'tampered promotion failure is unclear'
mv "$TMP_ROOT/promotion.tsv" "$RUN_DIR/promotion.tsv"

cp "$CARE_SUMMARY" "$TMP_ROOT/care-summary.backup.json"
python3 - "$CARE_SUMMARY" <<'PY'
import json,sys
path=sys.argv[1]
value=json.load(open(path,encoding="utf-8"))
value["policy"] += 1
with open(path,"w",encoding="utf-8") as target:
    json.dump(value,target)
PY
if "$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
    --output "$TMP_ROOT/stale-care" --care-summary "$CARE_SUMMARY" \
    >"$TMP_ROOT/stale-care.out" 2>&1; then
  fail 'care evidence from another policy was accepted'
fi
grep -F 'care summary is invalid' "$TMP_ROOT/stale-care.out" >/dev/null || \
  fail 'stale care failure is unclear'
mv "$TMP_ROOT/care-summary.backup.json" "$CARE_SUMMARY"

cp "$CARE_EVALS" "$TMP_ROOT/evals.backup.json"
printf 'tampered\n' >>"$CARE_EVALS"
if "$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
    --output "$TMP_ROOT/tampered-care-input" --care-summary "$CARE_SUMMARY" \
    >"$TMP_ROOT/tampered-care-input.out" 2>&1; then
  fail 'tampered care input was accepted'
fi
grep -F 'care input digest does not match: evals.json' \
  "$TMP_ROOT/tampered-care-input.out" >/dev/null || \
  fail 'tampered care input failure is unclear'
mv "$TMP_ROOT/evals.backup.json" "$CARE_EVALS"

cp "$RUN_DIR/manifest.tsv" "$TMP_ROOT/current-manifest.tsv"
awk -F '\t' '$1 != "specs" {print}' "$TMP_ROOT/current-manifest.tsv" \
  >"$RUN_DIR/manifest.tsv"
if "$ROOT/scripts/quality-dashboard" generate --result-root "$RESULT_ROOT" \
    --output "$TMP_ROOT/missing-specs" >"$TMP_ROOT/missing-specs.out" 2>&1; then
  fail 'current evidence without affected specs was accepted'
fi
grep -F 'manifest is missing: specs' "$TMP_ROOT/missing-specs.out" >/dev/null || \
  fail 'missing affected-spec failure is unclear'
mv "$TMP_ROOT/current-manifest.tsv" "$RUN_DIR/manifest.tsv"

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
