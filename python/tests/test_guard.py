"""Unit tests for the node-down guard (guard/node_guard.py).

No cluster, no docker, no AWS: a fake client records what the
guard would do, and a fake checker answers the second-source
question. Run with: python -m unittest discover -s python/tests -v
"""
import copy
import json
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "guard"))
import node_guard  # noqa: E402


def make_node(name, ready="True", transition="2026-11-24T06:00:00Z",
              annotations=None, taints=None, provider_id=""):
    node = {
        "metadata": {"name": name, "annotations": annotations or {}},
        "spec": {"taints": taints or [], "providerID": provider_id},
        "status": {"conditions": [
            {"type": "Ready", "status": ready, "lastTransitionTime": transition}
        ]},
    }
    return node


OOS = {"key": "node.kubernetes.io/out-of-service",
       "value": "nodeshutdown", "effect": "NoExecute"}


class FakeClient:
    """Records taint/untaint calls instead of touching a cluster."""

    def __init__(self, nodes):
        self.nodes = copy.deepcopy(nodes)
        self.tainted = []
        self.untainted = []

    def list_nodes(self):
        return copy.deepcopy(self.nodes)

    def apply_taint(self, name):
        self.tainted.append(name)

    def remove_taint(self, name):
        self.untainted.append(name)


class FakeChecker:
    """Answers the second-source question from a fixed map."""

    def __init__(self, answers):
        self.answers = answers  # node name -> True/False/None

    def is_down(self, node):
        return self.answers.get(node["metadata"]["name"])


NOW = 1795500000 + 3600  # 2026-11-24T07:00:00Z, 1h after the 06:00 transition


class TestGuardDecisions(unittest.TestCase):
    def run_guard(self, nodes, answers, dry_run=False, threshold=180):
        client = FakeClient(nodes)
        guard = node_guard.Guard(client, FakeChecker(answers),
                                 unreachable_seconds=threshold,
                                 dry_run=dry_run, audit=[])
        guard.evaluate(now=NOW)
        return client, guard.audit

    def decisions(self, audit):
        return {e["node"]: e["decision"] for e in audit}

    def test_healthy_node_is_skipped(self):
        _, audit = self.run_guard([make_node("worker-1")], {})
        self.assertEqual(self.decisions(audit), {"worker-1": "skip-ready"})

    def test_unreachable_short_of_threshold_is_skipped(self):
        # Transition 60s ago, threshold 180s: not long enough.
        node = make_node("worker-1", ready="Unknown",
                         transition="2026-11-24T06:59:00Z")
        _, audit = self.run_guard([node], {"worker-1": True})
        self.assertEqual(self.decisions(audit),
                         {"worker-1": "skip-unreachable-short"})

    def test_unreachable_long_enough_and_instance_down_taints(self):
        node = make_node("worker-1", ready="Unknown")  # 1h unreachable
        client, audit = self.run_guard([node], {"worker-1": True})
        self.assertEqual(client.tainted, ["worker-1"])
        self.assertEqual(self.decisions(audit), {"worker-1": "taint"})
        self.assertEqual(audit[0]["unreachable_seconds"], 3600)

    def test_maintenance_annotation_refuses(self):
        node = make_node("worker-1", ready="Unknown",
                         annotations={"csi-guard/maintenance": "true"})
        client, audit = self.run_guard([node], {"worker-1": True})
        self.assertEqual(client.tainted, [])
        self.assertEqual(self.decisions(audit),
                         {"worker-1": "refuse-maintenance"})

    def test_instance_still_running_refuses(self):
        node = make_node("worker-1", ready="False")
        client, audit = self.run_guard([node], {"worker-1": False})
        self.assertEqual(client.tainted, [])
        self.assertEqual(self.decisions(audit),
                         {"worker-1": "refuse-instance-running"})

    def test_checker_cannot_tell_refuses(self):
        node = make_node("worker-1", ready="False")
        client, audit = self.run_guard([node], {"worker-1": None})
        self.assertEqual(client.tainted, [])
        self.assertEqual(self.decisions(audit),
                         {"worker-1": "refuse-instance-unknown"})

    def test_dry_run_decides_but_applies_nothing(self):
        node = make_node("worker-1", ready="Unknown")
        client, audit = self.run_guard([node], {"worker-1": True}, dry_run=True)
        self.assertEqual(client.tainted, [])
        self.assertEqual(self.decisions(audit), {"worker-1": "would-taint"})
        self.assertTrue(audit[0]["dry_run"])

    def test_recovered_node_with_guard_taint_is_untainted(self):
        node = make_node("worker-1", ready="True",
                         annotations={"csi-guard/tainted-by": "node-guard"},
                         taints=[OOS])
        client, audit = self.run_guard([node], {})
        self.assertEqual(client.untainted, ["worker-1"])
        self.assertEqual(self.decisions(audit), {"worker-1": "untaint"})

    def test_recovered_node_with_human_taint_is_left_alone(self):
        node = make_node("worker-1", ready="True", taints=[OOS])
        client, audit = self.run_guard([node], {})
        self.assertEqual(client.untainted, [])
        self.assertEqual(self.decisions(audit),
                         {"worker-1": "skip-human-taint"})

    def test_missing_transition_time_refuses(self):
        node = make_node("worker-1", ready="Unknown", transition=None)
        node["status"]["conditions"][0].pop("lastTransitionTime")
        client, audit = self.run_guard([node], {"worker-1": True})
        self.assertEqual(client.tainted, [])
        self.assertEqual(self.decisions(audit),
                         {"worker-1": "refuse-unknown-transition"})

    def test_audit_lines_are_valid_json(self):
        node = make_node("worker-1", ready="Unknown")
        _, audit = self.run_guard([node], {"worker-1": True})
        for entry in audit:
            self.assertEqual(json.loads(json.dumps(entry)), entry)
            self.assertIn("node", entry)
            self.assertIn("decision", entry)
            self.assertIn("reason", entry)


class TestGuardManifests(unittest.TestCase):
    def load_all(self, path):
        with open(path) as f:
            return [d for d in yaml.safe_load_all(f) if d]

    def test_cronjob(self):
        docs = self.load_all(ROOT / "k8s" / "guard" / "cronjob.yaml")
        job = [d for d in docs if d["kind"] == "CronJob"][0]
        self.assertEqual(job["spec"]["schedule"], "*/2 * * * *")
        self.assertEqual(job["spec"]["concurrencyPolicy"], "Forbid")
        container = job["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
        self.assertEqual(container["image"], "python:3.12-slim")
        self.assertIn("node_guard.py", " ".join(container["command"]))
        self.assertIn("aws", container["command"])  # in-cluster checker
        self.assertEqual(
            job["spec"]["jobTemplate"]["spec"]["template"]["spec"]["serviceAccountName"],
            "node-guard")

    def test_rbac_allows_patch_on_nodes_only(self):
        docs = self.load_all(ROOT / "k8s" / "guard" / "rbac.yaml")
        role = [d for d in docs if d["kind"] == "ClusterRole"][0]
        self.assertEqual(len(role["rules"]), 1)
        rule = role["rules"][0]
        self.assertEqual(rule["resources"], ["nodes"])
        self.assertIn("patch", rule["verbs"])
        self.assertIn("get", rule["verbs"])
        self.assertIn("list", rule["verbs"])

    def test_configmap_matches_script(self):
        # The ConfigMap is generated from guard/node_guard.py; a
        # drift means the CronJob runs a different guard than the
        # one the unit tests cover.
        docs = self.load_all(ROOT / "k8s" / "guard" / "configmap.yaml")
        cm = [d for d in docs if d["kind"] == "ConfigMap"][0]
        embedded = cm["data"]["node_guard.py"]
        self.assertEqual(embedded, (ROOT / "guard" / "node_guard.py").read_text())

    def test_chaos_script_exists_and_asserts_no_taint(self):
        script = ROOT / "scripts" / "drills" / "guard_chaos_test.sh"
        self.assertTrue(script.exists())
        text = script.read_text()
        self.assertTrue(text.startswith("#!/usr/bin/env bash"))
        self.assertIn("set -euo pipefail", text)
        self.assertIn("--dry-run", text)
        self.assertIn("would-taint", text)
        self.assertIn("guard false-positive test", text)


if __name__ == "__main__":
    unittest.main()
