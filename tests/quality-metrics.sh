#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || {
  printf 'quality metrics contracts: python3 is required\n' >&2
  exit 2
}
exec python3 "$ROOT/tests/quality_metrics_contract.py"
