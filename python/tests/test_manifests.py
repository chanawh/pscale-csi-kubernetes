"""Checks for the CSI manifests, Helm values, and Terraform.

No cluster, no OneFS, no AWS account needed. Parses every YAML
file, checks the fields the driver actually requires, and checks
that the snapshot / clone / restore manifests agree with the
StorageClass and PVC they refer to. Run with:
  python -m unittest discover -s python/tests -v
"""
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


def load_all(path):
    with open(path) as f:
        return [d for d in yaml.safe_load_all(f) if d]


def by_kind(docs, kind):
    return [d for d in docs if d.get("kind") == kind]


class TestManifests(unittest.TestCase):
    def test_storageclass(self):
        docs = load_all(ROOT / "k8s" / "storageclass.yaml")
        scs = by_kind(docs, "StorageClass")
        self.assertEqual(len(scs), 2)
        main = [s for s in scs if s["metadata"]["name"] == "powerscale"][0]
        self.assertEqual(main["provisioner"], "csi-isilon.dellemc.com")
        self.assertEqual(main["parameters"]["IsiPath"], "/ifs/data/csi")
        self.assertEqual(main["parameters"]["AccessZone"], "System")
        self.assertTrue(main["allowVolumeExpansion"])
        self.assertEqual(main["volumeBindingMode"], "WaitForFirstConsumer")
        # Every class must allow expansion, or the expand drill cannot run.
        for sc in scs:
            self.assertTrue(sc["allowVolumeExpansion"], sc["metadata"]["name"])

    def test_snapshotclass_matches_storageclass(self):
        docs = load_all(ROOT / "k8s" / "snapshotclass.yaml")
        snap = by_kind(docs, "VolumeSnapshotClass")[0]
        self.assertEqual(snap["driver"], "csi-isilon.dellemc.com")
        self.assertEqual(snap["parameters"]["IsiPath"], "/ifs/data/csi")

    def test_pvc(self):
        docs = load_all(ROOT / "k8s" / "pvc-postgres.yaml")
        pvc = by_kind(docs, "PersistentVolumeClaim")[0]
        self.assertEqual(pvc["metadata"]["name"], "postgres-data")
        self.assertEqual(pvc["spec"]["storageClassName"], "powerscale")
        self.assertIn("ReadWriteMany", pvc["spec"]["accessModes"])
        size = pvc["spec"]["resources"]["requests"]["storage"]
        self.assertEqual(size, "10Gi")  # driver minimum is 3Gi

    def test_statefulset_uses_pvc(self):
        docs = load_all(ROOT / "k8s" / "postgres-statefulset.yaml")
        sts = by_kind(docs, "StatefulSet")[0]
        vols = sts["spec"]["template"]["spec"]["volumes"]
        claim = [v for v in vols if "persistentVolumeClaim" in v][0]
        self.assertEqual(claim["persistentVolumeClaim"]["claimName"], "postgres-data")
        # No volumeClaimTemplates: the PVC is the standalone claim,
        # so snapshot / clone / expand all target the same name.
        self.assertNotIn("volumeClaimTemplates", sts["spec"])

    def test_snapshot_and_restore_agree(self):
        snap = load_all(ROOT / "k8s" / "snapshot.yaml")
        vs = by_kind(snap, "VolumeSnapshot")[0]
        self.assertEqual(vs["spec"]["source"]["persistentVolumeClaimName"], "postgres-data")
        self.assertEqual(vs["spec"]["volumeSnapshotClassName"], "powerscale-snapclass")
        restored = load_all(ROOT / "k8s" / "pvc-from-snapshot.yaml")
        pvc = by_kind(restored, "PersistentVolumeClaim")[0]
        self.assertEqual(pvc["spec"]["dataSource"]["name"], vs["metadata"]["name"])
        self.assertEqual(pvc["spec"]["dataSource"]["kind"], "VolumeSnapshot")

    def test_clone_source_is_postgres_pvc(self):
        docs = load_all(ROOT / "k8s" / "pvc-clone.yaml")
        pvc = by_kind(docs, "PersistentVolumeClaim")[0]
        self.assertEqual(pvc["spec"]["dataSource"]["name"], "postgres-data")
        self.assertEqual(pvc["spec"]["dataSource"]["kind"], "PersistentVolumeClaim")

    def test_helm_values(self):
        with open(ROOT / "helm" / "values.yaml") as f:
            values = yaml.safe_load(f)
        self.assertEqual(values["version"], "v2.18.1")
        self.assertEqual(values["isiPath"], "/ifs/data/csi")
        self.assertEqual(values["isiAccessZone"], "System")
        self.assertTrue(values["enableQuota"])
        self.assertEqual(values["endpointPort"], 8080)

    def test_kind_config_has_two_workers(self):
        with open(ROOT / "scripts" / "kind-config.yaml") as f:
            cfg = yaml.safe_load(f)
        workers = [n for n in cfg["nodes"] if n.get("role") == "worker"]
        self.assertEqual(len(workers), 2, "node-failure drill needs 2 workers")

    def test_no_real_credentials_committed(self):
        for p in ROOT.rglob("*"):
            if p.is_file() and p.suffix in {".yaml", ".yml", ".tf", ".md", ".sh"}:
                if "example" in p.name or ".git/" in str(p):
                    continue
                text = p.read_text(errors="ignore")
                self.assertNotIn("CHANGE-ME", text, str(p))
        example = (ROOT / "helm" / "isilon-creds.yaml.example").read_text()
        self.assertIn("CHANGE-ME", example)
        self.assertFalse((ROOT / "helm" / "isilon-creds.yaml").exists(), "filled-in creds file must never be committed")


if __name__ == "__main__":
    unittest.main()
