#!/usr/bin/env python3
"""Build the CNPG-vs-single-replica comparison from drill evidence.

The comparison is a pure function of the evidence files the
drills already write — it runs no cluster and invents no
numbers. Each arm is either measured (its evidence file
exists and its trials completed) or "not measured" (the
file is absent, or the arm failed), and the reason is
recorded either way.

Arms (see docs/HA_COMPARISON.md):
  cnpg        — CloudNativePG HA, 2 replicas, operator
                failover. Source: evidence/cnpg-failover.json
                (median_serving_seconds).
  single      — single-replica StatefulSet, manual
                out-of-service taint. Source:
                evidence/node-failure-drill.json, case
                hard_stop_out_of_service_taint.
  single_guard — single-replica StatefulSet, the guard
                applies the taint. Source:
                evidence/guard-live.json
                (live_guard_median_serving_seconds).
  rpo         — the RPO measured alongside the CNPG arm.
                Source: evidence/rpo-<date>.json.

The comparison records the numbers and which arm was
fastest (by median kill-to-serving seconds); it does not
editorialise — the trade-off notes live in the doc.
Stdlib only.
"""
import json
import sys
from pathlib import Path


def load_json(path):
    """An evidence file as a dict, or None when it is absent
    or unparseable (a missing arm, not a crash)."""
    if path is None:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return None


def median(values):
    """Median of the non-None values, or None when there are none."""
    numbers = sorted(v for v in values if v is not None)
    if not numbers:
        return None
    return numbers[len(numbers) // 2]


def _num(value):
    return value if isinstance(value, (int, float)) else None


def cnpg_arm(evidence):
    """The CNPG arm from evidence/cnpg-failover.json."""
    if not evidence:
        return {"measured": False,
                "reason": "evidence/cnpg-failover.json absent"}
    trials = evidence.get("failover_trials") or []
    serving = [_num(t.get("kill_to_serving_seconds")) for t in trials]
    ready = [_num(t.get("kill_to_ready_seconds")) for t in trials]
    failed = [t for t in trials if t.get("failed") is True]
    row_intact = [t.get("row_intact") for t in trials]
    arm = {
        "measured": evidence.get("median_serving_seconds") is not None,
        "median_serving_seconds": evidence.get("median_serving_seconds"),
        "median_ready_seconds": median(ready),
        "trials": len(trials),
        "failed_trials": len(failed),
        "row_intact": all(r is True for r in row_intact) if row_intact else None,
        "evidence": "evidence/cnpg-failover.json",
    }
    if not arm["measured"]:
        arm["reason"] = "CNPG drill did not complete a serving trial"
    return arm


def single_arm(evidence):
    """The single-replica manual-taint arm from
    evidence/node-failure-drill.json (case 3). The drill
    exits non-zero if the row does not read back, so a
    completed drill implies the row was intact."""
    if not evidence:
        return {"measured": False,
                "reason": "evidence/node-failure-drill.json absent"}
    cases = evidence.get("cases") or {}
    taint = cases.get("hard_stop_out_of_service_taint") or {}
    serving = _num(taint.get("serving_seconds"))
    arm = {
        "measured": serving is not None,
        "median_serving_seconds": serving,
        "median_ready_seconds": _num(taint.get("ready_seconds")),
        "trials": 1 if serving is not None else 0,
        "failed_trials": 0 if evidence.get("completed") else 1,
        "row_intact": True if evidence.get("completed") else None,
        "evidence": "evidence/node-failure-drill.json",
    }
    if not arm["measured"]:
        arm["reason"] = "node-failure drill did not complete the " \
            "out-of-service-taint case"
    return arm


def guard_arm(evidence):
    """The single-replica guard arm from evidence/guard-live.json."""
    if not evidence:
        return {"measured": False,
                "reason": "evidence/guard-live.json absent — run the "
                          "guard-live drill first, or re-run with "
                          "--with-guard"}
    serving = evidence.get("live_guard_median_serving_seconds")
    refusals = evidence.get("refusal_trials") or []
    refused = sum(1 for r in refusals if r.get("refused") is True)
    live = evidence.get("live_guard_trials") or []
    ready = [_num(t.get("kill_to_ready_seconds")) for t in live]
    arm = {
        "measured": serving is not None,
        "median_serving_seconds": serving,
        "median_ready_seconds": median(ready),
        "trials": len([t for t in live
                       if t.get("kill_to_serving_seconds") is not None]),
        "failed_trials": 0,
        "row_intact": None,
        "refusals": {"refused": refused, "of": len(refusals)},
        "evidence": "evidence/guard-live.json",
    }
    if not arm["measured"]:
        arm["reason"] = "guard-live drill did not complete a serving trial"
    return arm


def rpo_part(evidence):
    """The RPO measured alongside the CNPG arm, from
    evidence/rpo-<date>.json."""
    if not evidence:
        return {"measured": False,
                "reason": "evidence/rpo-<date>.json absent"}
    failover = evidence.get("failover_rpo") or {}
    archive = evidence.get("archive_rpo") or {}
    return {
        "measured": evidence.get("measured") is True,
        "failover_rpo_max_lag_seconds": failover.get("max_lag_seconds"),
        "failover_rpo_max_lag_bytes": failover.get("max_lag_bytes"),
        "archive_rpo_configured": archive.get("configured") is True,
        "archive_rpo_lag_seconds": archive.get("lag_seconds"),
        "archive_rpo_lag_bytes": archive.get("lag_bytes"),
        "evidence": "evidence/rpo-<date>.json",
    }


def build_comparison(cnpg, single, guard, rpo, scope):
    """The comparison dict from the four arm dicts. No arm is
    required: a missing arm is recorded, not invented."""
    arms = {
        "cnpg_ha": cnpg_arm(cnpg),
        "single_replica_manual_taint": single_arm(single),
        "single_replica_guard": guard_arm(guard),
    }
    comparison = {
        "scope": scope,
        "arms": arms,
        "rpo": rpo_part(rpo),
        "cost": {
            "kind_ci": "$0 (GitHub Actions, public repo)",
            "eks_one_day": "about $4.50-5.00 (docs/COST.md)",
        },
    }
    serving = {name: arm.get("median_serving_seconds")
               for name, arm in arms.items()}
    serving = {n: s for n, s in serving.items() if s is not None}
    if serving:
        fastest = min(serving, key=serving.get)
        comparison["fastest"] = fastest
        comparison["deltas_seconds"] = {
            name: seconds - serving[fastest]
            for name, seconds in serving.items()
        }
    else:
        comparison["fastest"] = None
        comparison["deltas_seconds"] = {}
    return comparison


def write_evidence(comparison, path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(comparison, f, indent=2)
    return path


def main(argv=None):
    import argparse
    parser = argparse.ArgumentParser(
        description="Build the CNPG-vs-single-replica comparison "
                    "from drill evidence files.")
    parser.add_argument("--cnpg", default=None)
    parser.add_argument("--single", default=None)
    parser.add_argument("--guard", default=None)
    parser.add_argument("--rpo", default=None)
    parser.add_argument("--scope", required=True)
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args(argv)
    comparison = build_comparison(
        load_json(args.cnpg), load_json(args.single),
        load_json(args.guard), load_json(args.rpo), args.scope)
    path = write_evidence(comparison, args.evidence)
    print(open(path).read())
    print("evidence written to %s" % path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
