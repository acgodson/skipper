#!/usr/bin/env bash
# Snapshot / verify that the production gptc service is untouched.
#   ./preflight.sh            capture baseline
#   ./preflight.sh --verify   compare against baseline, non-zero exit on any drift
set -euo pipefail
cd "$(dirname "$0")"
source ./_ssm.sh
BASELINE="../.baseline.txt"

probe='docker ps --no-trunc --filter name=gptc --format "{{.Names}}|{{.Image}}|{{.State}}" | sort; echo "PORT8001=$(ss -ltn | grep -c 8001)"; echo "GPTCDIR=$(ls -1 /opt/gptc | sort | tr "\n" ",")"'

snapshot=$(ssm_run_ro "$probe")

if [[ "${1:-}" == "--verify" ]]; then
  [[ -f "$BASELINE" ]] || { echo "FAIL: no baseline; run ./preflight.sh first" >&2; exit 1; }
  if diff -u "$BASELINE" <(echo "$snapshot"); then
    echo "PASS: production gptc service is unchanged."
  else
    echo "FAIL: gptc state drifted from baseline (diff above). Investigate before continuing." >&2
    exit 1
  fi
else
  echo "$snapshot" | tee "$BASELINE"
  echo
  if echo "$snapshot" | grep -q 'gptc-api-1|.*|running'; then
    echo "PASS: gptc-api-1 is running. Baseline written to $BASELINE"
  else
    echo "FAIL: gptc-api-1 is not running — do NOT deploy until this is understood." >&2
    exit 1
  fi
fi
