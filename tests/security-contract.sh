#!/bin/bash

set -euo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || {
  printf 'security automation contracts: python3 is required\n' >&2
  exit 2
}
exec python3 "$ROOT/tests/security_contract.py"
