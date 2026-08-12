#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/tests/quality_care_contract.py"
