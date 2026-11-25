#!/usr/bin/env bash
# False-positive test for the node-down guard, run in the CI drill
# workflow while the kind cluster is healthy.
#
# The guard's dangerous failure is tainting a live node: a
# force-delete on a running node risks two writers on one volume.
# So the test runs the guard in dry-run mode against a healthy
# cluster and asserts every decision is a skip or a refusal —
# no taint, not even a would-taint. A would-taint on a healthy
# cluster means the guard's conditions are wrong, and the test
# fails before the guard is ever allowed near a live mode.
#
# Requires: python3, kubectl with a context, a healthy cluster.
# No docker, no AWS, no live mode. The true-positive path (guard
# applies the taint after a real kill) and the refusal trials
# (guard refuses a live, paused node) are covered by
# scripts/drills/guard_live_ci.sh, run by
# .github/workflows/guard-live-drill.yml; this test is the
# healthy-cluster half that runs first in the manual drill.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$(mktemp)"
trap 'rm -f "$AUDIT"' EXIT

echo "== guard false-positive test: dry-run on a healthy cluster =="
python3 "$ROOT/guard/node_guard.py" \
  --client kubectl --checker kind --cluster-name pscale-csi \
  --unreachable-seconds 180 --dry-run --audit-file "$AUDIT" \
  > /tmp/guard-chaos-stdout.txt

python3 - "$AUDIT" <<'PY'
import json, sys
decisions = [json.loads(line)["decision"] for line in open(sys.argv[1]) if line.strip()]
print(f"guard decisions on healthy cluster: {decisions}")
bad = [d for d in decisions if d in ("taint", "would-taint", "untaint", "error")]
assert decisions, "guard made no decisions at all — did it see the nodes?"
assert not bad, f"guard would act on a healthy cluster: {bad}"
assert all(d.startswith(("skip-", "refuse-")) for d in decisions), decisions
print("guard false-positive test: PASS (no taint decisions on healthy nodes)")
PY
