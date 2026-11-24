#!/usr/bin/env python3
"""Regenerate k8s/guard/configmap.yaml from guard/node_guard.py.

The CronJob mounts the script from a ConfigMap, which means the
script exists twice in the repo. This generator is the single
source of truth: edit guard/node_guard.py, run this, commit
both. A test (python/tests/test_guard.py) asserts the ConfigMap
content matches the script byte for byte, so a drift fails CI.

Usage: python3 guard/generate_configmap.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = """# ConfigMap holding the guard script for the CronJob.
# GENERATED from guard/node_guard.py — do not edit by hand.
# Regenerate with: python3 guard/generate_configmap.py
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-guard-script
  namespace: csi-demo
data:
  node_guard.py: |
"""


def main():
    script = (ROOT / "guard" / "node_guard.py").read_text()
    out = ROOT / "k8s" / "guard" / "configmap.yaml"
    with open(out, "w") as f:
        f.write(HEADER)
        for line in script.splitlines():
            f.write("    " + line + "\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
