#!/usr/bin/env python3
"""Node-down guard: apply the out-of-service taint, but only when it is safe.

The measured fact behind this guard (CI drill run 45339015253, kind +
in-cluster NFS, evidence in evidence/node-failure-drill.json): a
StatefulSet pod on a dead node does not recover on its own. It sat
Running/NotReady for 240s with no replacement. Applying the
out-of-service taint recovered it in ~15s (198s from the kill, most of
it the drill script waiting on a lagging NotReady flag). The taint is
the supported fix, but it is dangerous to apply blindly: force-deleting
a pod on a node that is still running risks two writers on one volume
(the old kubelet and the rescheduled pod both holding the same
PersistentVolume). This guard applies the taint only when ALL hold:

  1. the node's Ready condition has been False or Unknown for at least
     --unreachable-seconds (default 180s), measured from the
     condition's lastTransitionTime, not from when the guard noticed;
  2. a second source confirms the instance is actually down
     (--checker kind: the kind container is stopped;
      --checker aws: the EC2 instance is stopped or terminated);
  3. the node carries no maintenance annotation
     (csi-guard/maintenance: "true").

If any check fails or cannot be answered, the guard refuses and says
so in the audit log. A refused taint is a safe outcome; a wrong taint
is a data-corruption outcome.

The guard is stateless and runs as a CronJob (k8s/guard/): it reads
lastTransitionTime from the API, so it does not need to remember
anything between runs. It only ever removes a taint it applied
itself (marked by the csi-guard/tainted-by=node-guard annotation);
a human-applied taint is left alone. Dry-run mode decides and
logs without applying anything.

Usage (local, against kind):
  kubectl proxy --port=8001 &
  python3 guard/node_guard.py --client kubectl --checker kind --dry-run
Usage (in-cluster CronJob):
  python3 guard/node_guard.py --client api --checker aws
Audit output is one JSON object per line, on stdout (and --audit-file
if given). Exit 0 unless a client call fails outright (exit 2).
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

OUT_OF_SERVICE_KEY = "node.kubernetes.io/out-of-service"
OUT_OF_SERVICE_VALUE = "nodeshutdown"
MAINTENANCE_ANNOTATION = "csi-guard/maintenance"
MARKER_ANNOTATION = "csi-guard/tainted-by"
MARKER_VALUE = "node-guard"
DEFAULT_UNREACHABLE_SECONDS = 180


def parse_time(value):
    """ISO 8601 (e.g. 2026-11-24T06:00:00Z) to epoch seconds, or None."""
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def ready_condition(node):
    """(status, last_transition_epoch) of the node's Ready condition."""
    for cond in node.get("status", {}).get("conditions", []):
        if cond.get("type") == "Ready":
            return cond.get("status"), parse_time(cond.get("lastTransitionTime"))
    return None, None


def node_summary(node):
    """The fields the guard decides on, from one raw node object."""
    status, last_transition = ready_condition(node)
    annotations = node.get("metadata", {}).get("annotations", {}) or {}
    taints = node.get("spec", {}).get("taints", []) or []
    return {
        "name": node.get("metadata", {}).get("name", ""),
        "ready": status,
        "last_transition": last_transition,
        "annotations": annotations,
        "taints": taints,
        "provider_id": node.get("spec", {}).get("providerID", ""),
        "has_oos_taint": any(t.get("key") == OUT_OF_SERVICE_KEY for t in taints),
        "guard_tainted": annotations.get(MARKER_ANNOTATION) == MARKER_VALUE,
        "maintenance": annotations.get(MAINTENANCE_ANNOTATION) == "true",
    }


class KubectlClient:
    """Node client that shells out to kubectl (local runs, kind, CI)."""

    def list_nodes(self):
        out = subprocess.check_output(
            ["kubectl", "get", "nodes", "-o", "json"], text=True
        )
        return json.loads(out)["items"]

    def apply_taint(self, name):
        subprocess.check_call([
            "kubectl", "taint", "nodes", name,
            f"{OUT_OF_SERVICE_KEY}={OUT_OF_SERVICE_VALUE}:NoExecute",
            "--overwrite",
        ])
        subprocess.check_call([
            "kubectl", "annotate", "node", name,
            f"{MARKER_ANNOTATION}={MARKER_VALUE}", "--overwrite",
        ])

    def remove_taint(self, name):
        subprocess.check_call([
            "kubectl", "taint", "nodes", name,
            f"{OUT_OF_SERVICE_KEY}-",
        ])
        subprocess.check_call([
            "kubectl", "annotate", "node", name,
            f"{MARKER_ANNOTATION}-",
        ])


class K8sApiClient:
    """Node client over the Kubernetes API with stdlib urllib only.

    In-cluster: token and CA from the service-account mount, host/port
    from KUBERNETES_SERVICE_HOST/PORT. Local: --api-server plus
    --token-file. No client library, no kubectl binary needed, so the
    CronJob image is plain python:3.12-slim.
    """

    def __init__(self, api_server=None, token=None, ca_file=None):
        host = api_server or os.environ.get("KUBERNETES_SERVICE_HOST")
        port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
        if not host:
            raise ValueError("no API server: pass --api-server or run in-cluster")
        self.base = f"https://{host}:{port}"
        self.token = token
        if self.token is None:
            token_file = "/var/run/secrets/kubernetes.io/serviceaccount/token"
            with open(token_file) as f:
                self.token = f.read().strip()
        self.ca_file = ca_file or (
            "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
            if os.path.exists("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
            else None
        )

    def _request(self, method, path, body=None, content_type=None):
        import ssl

        ctx = ssl.create_default_context(cafile=self.ca_file)
        req = urllib.request.Request(
            self.base + path, method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": content_type or "application/json",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            return json.loads(resp.read().decode())

    def list_nodes(self):
        return self._request("GET", "/api/v1/nodes")["items"]

    def apply_taint(self, name):
        node = self._request("GET", f"/api/v1/nodes/{name}")
        taints = [t for t in node.get("spec", {}).get("taints", [])
                  if t.get("key") != OUT_OF_SERVICE_KEY]
        taints.append({"key": OUT_OF_SERVICE_KEY, "value": OUT_OF_SERVICE_VALUE,
                       "effect": "NoExecute"})
        self._request("PATCH", f"/api/v1/nodes/{name}", {
            "spec": {"taints": taints},
            "metadata": {"annotations": {MARKER_ANNOTATION: MARKER_VALUE}},
        }, content_type="application/merge-patch+json")

    def remove_taint(self, name):
        node = self._request("GET", f"/api/v1/nodes/{name}")
        taints = [t for t in node.get("spec", {}).get("taints", [])
                  if t.get("key") != OUT_OF_SERVICE_KEY]
        self._request("PATCH", f"/api/v1/nodes/{name}", {
            "spec": {"taints": taints},
            "metadata": {"annotations": {MARKER_ANNOTATION: None}},
        }, content_type="application/merge-patch+json")


class KindChecker:
    """Second source for kind: the node's container must be stopped.

    kind names a node's container after the node (pscale-csi-worker),
    so the node name is the container name. A container that is
    running means the kubelet may still be alive: refuse.
    """

    def __init__(self, cluster_name="pscale-csi"):
        self.cluster_name = cluster_name

    def is_down(self, node):
        name = node.get("metadata", {}).get("name", "")
        try:
            out = subprocess.check_output(
                ["docker", "inspect", "-f", "{{.State.Status}}", name],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            return None  # cannot tell: refuse, do not guess
        if out in ("exited", "dead"):
            return True
        if out == "running":
            return False
        return None


class AwsChecker:
    """Second source for EKS: the EC2 instance must be stopped/terminated.

    Reads the instance id from the node's providerID
    (aws:///<az>/<instance-id>) and asks EC2. Any CLI failure
    returns None: refuse, do not guess.
    """

    def is_down(self, node):
        provider_id = node.get("spec", {}).get("providerID", "")
        instance_id = provider_id.rsplit("/", 1)[-1] if "/" in provider_id else ""
        if not instance_id.startswith("i-"):
            return None
        try:
            out = subprocess.check_output([
                "aws", "ec2", "describe-instances",
                "--instance-ids", instance_id,
                "--query", "Reservations[0].Instances[0].State.Name",
                "--output", "text",
            ], text=True, stderr=subprocess.DEVNULL).strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            return None
        if out in ("stopped", "terminated", "stopping", "shutting-down"):
            return True
        if out in ("running", "pending"):
            return False
        return None


class Guard:
    """Decides taint / refuse / untaint for every node, once."""

    def __init__(self, client, checker, unreachable_seconds=DEFAULT_UNREACHABLE_SECONDS,
                 dry_run=False, audit=None):
        self.client = client
        self.checker = checker
        self.unreachable_seconds = unreachable_seconds
        self.dry_run = dry_run
        self.audit = audit if audit is not None else []

    def _log(self, node_name, decision, reason, **extra):
        entry = {"ts": int(time.time()), "node": node_name,
                 "decision": decision, "reason": reason, "dry_run": self.dry_run}
        entry.update(extra)
        self.audit.append(entry)
        print(json.dumps(entry), flush=True)

    def evaluate(self, now=None):
        """One pass over all nodes. Returns the audit entries."""
        now = now if now is not None else time.time()
        try:
            nodes = self.client.list_nodes()
        except Exception as exc:  # noqa: BLE001 - surfaced to the caller
            self._log("", "error", f"list-nodes-failed: {exc}")
            raise
        for raw in nodes:
            node = node_summary(raw)
            name = node["name"]
            # Auto-removal: the node is back and the taint is ours.
            if node["has_oos_taint"] and node["ready"] == "True":
                if node["guard_tainted"]:
                    if not self.dry_run:
                        self.client.remove_taint(name)
                    self._log(name, "untaint", "node-ready-again")
                else:
                    self._log(name, "skip-human-taint",
                              "out-of-service taint not applied by this guard")
                continue
            if node["ready"] == "True":
                self._log(name, "skip-ready", "node is Ready")
                continue
            if node["maintenance"]:
                self._log(name, "refuse-maintenance",
                          "maintenance annotation set")
                continue
            if node["last_transition"] is None:
                self._log(name, "refuse-unknown-transition",
                          "Ready condition has no lastTransitionTime")
                continue
            unreachable_for = now - node["last_transition"]
            if unreachable_for < self.unreachable_seconds:
                self._log(name, "skip-unreachable-short",
                          f"unreachable {int(unreachable_for)}s "
                          f"< {self.unreachable_seconds}s threshold",
                          unreachable_seconds=int(unreachable_for))
                continue
            down = self.checker.is_down(raw)
            if down is False:
                self._log(name, "refuse-instance-running",
                          "second source says the instance is still running")
                continue
            if down is None:
                self._log(name, "refuse-instance-unknown",
                          "second source could not confirm the instance is down")
                continue
            if self.dry_run:
                self._log(name, "would-taint",
                          "all conditions hold (dry-run, nothing applied)",
                          unreachable_seconds=int(unreachable_for))
            else:
                self.client.apply_taint(name)
                self._log(name, "taint",
                          "all conditions hold; out-of-service taint applied",
                          unreachable_seconds=int(unreachable_for))
        return self.audit


def build_parser():
    p = argparse.ArgumentParser(description="Node-down guard (see module docstring).")
    p.add_argument("--client", choices=["kubectl", "api"], default="kubectl",
                   help="how to talk to the API (default: kubectl)")
    p.add_argument("--checker", choices=["kind", "aws"], default="kind",
                   help="second source confirming the instance is down")
    p.add_argument("--cluster-name", default="pscale-csi",
                   help="kind cluster name (kind checker only)")
    p.add_argument("--unreachable-seconds", type=int,
                   default=DEFAULT_UNREACHABLE_SECONDS,
                   help="how long Ready must be False/Unknown before tainting")
    p.add_argument("--dry-run", action="store_true",
                   help="decide and log, apply nothing")
    p.add_argument("--audit-file", help="append audit JSON lines here as well")
    p.add_argument("--api-server", help="API server host (api client only)")
    p.add_argument("--token-file", help="bearer token file (api client only)")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    token = None
    if args.token_file:
        with open(args.token_file) as f:
            token = f.read().strip()
    client = (KubectlClient() if args.client == "kubectl"
              else K8sApiClient(args.api_server, token))
    checker = (KindChecker(args.cluster_name) if args.checker == "kind"
               else AwsChecker())
    audit = []
    guard = Guard(client, checker, args.unreachable_seconds, args.dry_run, audit)
    try:
        guard.evaluate()
    except Exception as exc:  # noqa: BLE001 - audit already has the error line
        print(f"guard failed: {exc}", file=sys.stderr)
        return 2
    if args.audit_file:
        with open(args.audit_file, "a") as f:
            for entry in audit:
                f.write(json.dumps(entry) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
