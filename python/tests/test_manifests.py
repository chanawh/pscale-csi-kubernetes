"""Checks for the CSI manifests, Helm values, and Terraform.

No cluster, no OneFS, no AWS account needed. Parses every YAML
file, checks the fields the driver actually requires, and checks
that the snapshot / clone / restore manifests agree with the
StorageClass and PVC they refer to. Run with:
  python -m unittest discover -s python/tests -v
"""
import json
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
        # The CI drill claim is the same shape on the NFS class,
        # so a rescheduled pod can reattach on another node.
        nfs = by_kind(load_all(ROOT / "k8s" / "ci-drill" / "pvc-postgres-nfs.yaml"), "PersistentVolumeClaim")[0]
        self.assertEqual(nfs["metadata"]["name"], "postgres-data")
        self.assertEqual(nfs["spec"]["storageClassName"], "nfs")
        self.assertIn("ReadWriteMany", nfs["spec"]["accessModes"])
        self.assertEqual(nfs["spec"]["resources"]["requests"]["storage"], "10Gi")

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
            if p.is_file() and p.suffix in {".yaml", ".yml", ".tf", ".sh"}:
                if "example" in p.name or ".git/" in str(p):
                    continue
                text = p.read_text(errors="ignore")
                self.assertNotIn("CHANGE-ME", text, str(p))
        # .md files may mention CHANGE-ME as a reference to the
        # example file; only code and config must not contain it.
        example = (ROOT / "helm" / "isilon-creds.yaml.example").read_text()
        self.assertIn("CHANGE-ME", example)
        self.assertFalse((ROOT / "helm" / "isilon-creds.yaml").exists(), "filled-in creds file must never be committed")


class TestEksUpgrade(unittest.TestCase):
    """EKS path (v1.1.0): EBS + EFS CSI alongside PowerScale CSI."""

    def test_ebs_storageclass(self):
        docs = load_all(ROOT / "k8s" / "eks" / "storageclass-ebs.yaml")
        sc = by_kind(docs, "StorageClass")[0]
        self.assertEqual(sc["metadata"]["name"], "ebs-gp3")
        self.assertEqual(sc["provisioner"], "ebs.csi.aws.com")
        self.assertEqual(sc["parameters"]["type"], "gp3")
        self.assertEqual(sc["parameters"]["encrypted"], "true")
        self.assertTrue(sc["allowVolumeExpansion"])
        self.assertEqual(sc["volumeBindingMode"], "WaitForFirstConsumer")

    def test_efs_storageclass(self):
        docs = load_all(ROOT / "k8s" / "eks" / "storageclass-efs.yaml")
        sc = by_kind(docs, "StorageClass")[0]
        self.assertEqual(sc["metadata"]["name"], "efs")
        self.assertEqual(sc["provisioner"], "efs.csi.aws.com")
        self.assertEqual(sc["parameters"]["provisioningMode"], "efs-ap")
        # Substituted by scripts/eks/deploy_eks.sh from terraform
        # output; a real filesystem ID must never be committed.
        self.assertEqual(sc["parameters"]["fileSystemId"], "${EFS_FILE_SYSTEM_ID}")

    def test_ebs_workload_agrees(self):
        pvc = by_kind(load_all(ROOT / "k8s" / "eks" / "pvc-postgres-ebs.yaml"), "PersistentVolumeClaim")[0]
        self.assertEqual(pvc["metadata"]["name"], "postgres-data-ebs")
        self.assertEqual(pvc["spec"]["storageClassName"], "ebs-gp3")
        self.assertIn("ReadWriteOnce", pvc["spec"]["accessModes"])  # EBS is block
        sts = by_kind(load_all(ROOT / "k8s" / "eks" / "postgres-statefulset-ebs.yaml"), "StatefulSet")[0]
        vols = sts["spec"]["template"]["spec"]["volumes"]
        claim = [v for v in vols if "persistentVolumeClaim" in v][0]
        self.assertEqual(claim["persistentVolumeClaim"]["claimName"], "postgres-data-ebs")
        self.assertNotIn("volumeClaimTemplates", sts["spec"])

    def test_efs_pvc_is_rwx(self):
        pvc = by_kind(load_all(ROOT / "k8s" / "eks" / "pvc-shared-efs.yaml"), "PersistentVolumeClaim")[0]
        self.assertEqual(pvc["spec"]["storageClassName"], "efs")
        self.assertIn("ReadWriteMany", pvc["spec"]["accessModes"])  # EFS is file

    def test_ebs_snapshot_agrees(self):
        docs = load_all(ROOT / "k8s" / "eks" / "snapshot-ebs.yaml")
        vs = by_kind(docs, "VolumeSnapshot")[0]
        self.assertEqual(vs["spec"]["source"]["persistentVolumeClaimName"], "postgres-data-ebs")
        self.assertEqual(vs["spec"]["volumeSnapshotClassName"], "ebs-snapclass")
        snapclass = by_kind(load_all(ROOT / "k8s" / "eks" / "snapshotclass-ebs.yaml"), "VolumeSnapshotClass")[0]
        self.assertEqual(snapclass["driver"], "ebs.csi.aws.com")
        restored = [p for p in by_kind(docs, "PersistentVolumeClaim")][0]
        self.assertEqual(restored["spec"]["dataSource"]["name"], vs["metadata"]["name"])
        self.assertEqual(restored["spec"]["dataSource"]["kind"], "VolumeSnapshot")

    def test_observability_values(self):
        with open(ROOT / "helm" / "observability-values.yaml") as f:
            values = yaml.safe_load(f)
        self.assertIn("grafana", values)
        self.assertIn("prometheus", values)
        self.assertTrue(values["nodeExporter"]["enabled"])
        self.assertTrue(values["kubeStateMetrics"]["enabled"])
        self.assertEqual(values["prometheus"]["prometheusSpec"]["retention"], "24h")

    def test_terraform_eks_addons_and_pod_identity(self):
        eks = (ROOT / "terraform" / "eks.tf").read_text()
        for addon in ("aws-ebs-csi-driver", "aws-efs-csi-driver", "vpc-cni", "coredns", "kube-proxy"):
            self.assertIn(addon, eks, addon)
        self.assertIn("aws_eks_pod_identity_association", eks)
        self.assertIn("ebs-csi-controller-sa", eks)
        self.assertIn("efs-csi-controller-sa", eks)
        self.assertIn("enabled_cluster_log_types", eks)
        self.assertIn("encryption_config", eks)
        # Everything real-AWS stays gated off by default.
        variables = (ROOT / "terraform" / "variables.tf").read_text()
        self.assertIn('variable "enable_eks"', variables)
        efs = (ROOT / "terraform" / "efs.tf").read_text()
        self.assertIn("aws_efs_file_system", efs)
        self.assertIn("aws_efs_mount_target", efs)
        self.assertIn("2049", efs)

    def test_grafana_dashboard(self):
        dash = json.loads((ROOT / "monitoring" / "grafana" / "csi-storage-dashboard.json").read_text())
        self.assertEqual(dash["uid"], "csi-storage")
        self.assertEqual(len(dash["panels"]), 10)
        for panel in dash["panels"]:
            self.assertTrue(panel["targets"][0]["expr"].strip())
        # v1.2.0: availability panels backing the burn-rate alerts.
        titles = [p["title"] for p in dash["panels"]]
        self.assertIn("Postgres availability (5m avg)", titles)
        self.assertIn("Postgres availability (1h avg)", titles)

    def test_prometheus_alerts(self):
        docs = list(yaml.safe_load_all((ROOT / "monitoring" / "prometheus" / "csi-alerts.yaml").read_text()))
        rule = docs[0]
        self.assertEqual(rule["kind"], "PrometheusRule")
        rules = rule["spec"]["groups"][0]["rules"]
        self.assertEqual(len(rules), 7)
        for r in rules:
            self.assertTrue(r["expr"].strip())
            self.assertIn("severity", r["labels"])
        # v1.2.0: multi-window burn-rate alerts on the Ready SLI.
        names = [r["alert"] for r in rules]
        self.assertIn("PostgresAvailabilityBurnFast", names)
        self.assertIn("PostgresAvailabilityBurnSlow", names)
        for r in rules:
            if r["alert"].startswith("PostgresAvailabilityBurn"):
                self.assertIn("avg_over_time", r["expr"])
                self.assertIn("kube_pod_status_ready", r["expr"])

    def test_postgres_tolerations_tuned(self):
        for path in ("k8s/postgres-statefulset.yaml", "k8s/eks/postgres-statefulset-ebs.yaml"):
            docs = load_all(ROOT / path)
            sts = [d for d in docs if d.get("kind") == "StatefulSet"][0]
            tol = {x["key"]: x["tolerationSeconds"] for x in sts["spec"]["template"]["spec"]["tolerations"]}
            self.assertEqual(tol["node.kubernetes.io/not-ready"], 30)
            self.assertEqual(tol["node.kubernetes.io/unreachable"], 30)

    def test_eks_scripts_exist(self):
        for name in ("deploy_eks.sh", "run_eks_demo.sh", "destroy_eks.sh"):
            script = ROOT / "scripts" / "eks" / name
            self.assertTrue(script.exists(), name)
            text = script.read_text()
            self.assertTrue(text.startswith("#!/usr/bin/env bash"), name)
            self.assertIn("set -euo pipefail", text, name)
        # The demo must measure pod recovery, not estimate it.
        demo = (ROOT / "scripts" / "eks" / "run_eks_demo.sh").read_text()
        self.assertIn("kubectl drain", demo)
        self.assertIn("date +%s", demo)
        # Destroy must delete PVCs before terraform destroy, or
        # EBS volumes orphan and keep billing.
        destroy = (ROOT / "scripts" / "eks" / "destroy_eks.sh").read_text()
        delete_at = destroy.index("delete namespace csi-demo")
        self.assertLess(delete_at, destroy.index("terraform destroy", delete_at))


class TestCeilingV120(unittest.TestCase):
    """Ceiling v1.2.0: guard, CNPG, FIS, DR, SLOs, IaC scanning.

    Everything here is code/docs validated without a cluster or
    AWS account. Live timings are pending by design; the tests
    assert the artifacts exist, parse, and say what they claim.
    """

    def test_cnpg_cluster_manifest(self):
        docs = load_all(ROOT / "k8s" / "cnpg" / "cluster.yaml")
        cluster = [d for d in docs if d["kind"] == "Cluster"][0]
        self.assertEqual(cluster["spec"]["instances"], 2)
        self.assertEqual(cluster["spec"]["storage"]["size"], "10Gi")
        # kind + NFS run first; EKS swaps this to ebs-gp3.
        self.assertEqual(cluster["spec"]["storage"]["storageClass"], "nfs")
        self.assertEqual(cluster["spec"]["bootstrap"]["initdb"]["database"], "csi_demo")

    def test_fis_module(self):
        fis = ROOT / "terraform" / "fis"
        for name in ("versions.tf", "variables.tf", "main.tf", "outputs.tf"):
            self.assertTrue((fis / name).exists(), name)
        main = (fis / "main.tf").read_text()
        # The named AZ-loss scenario (EKS Workshop route).
        self.assertIn("AWSResilienceHub-SimulateAzOutageInAsgTest_2020-07-23", main)
        self.assertIn("aws:ssm:start-automation-execution", main)
        self.assertIn("aws_fis_experiment_template", main)
        self.assertIn("stop_condition", main)
        self.assertIn("log_schema_version", main)
        diy = json.loads((fis / "templates" / "diy-az-loss.json").read_text())
        self.assertIn("aws:network:disrupt-connectivity",
                      diy["actions"]["blockAzNetwork"]["actionId"])
        self.assertIn("aws:ec2:stop-instances",
                      diy["actions"]["stopAzInstances"]["actionId"])

    def test_dr_script(self):
        script = ROOT / "scripts" / "eks" / "dr_region_restore.sh"
        self.assertTrue(script.exists())
        text = script.read_text()
        self.assertTrue(text.startswith("#!/usr/bin/env bash"))
        self.assertIn("set -euo pipefail", text)
        self.assertIn("copy-snapshot", text)
        self.assertIn("create-volume", text)
        self.assertIn("dr-region.json", text)
        self.assertIn("rpo_seconds", text)
        self.assertIn("rto_seconds", text)

    def test_ceiling_docs_exist(self):
        for name in ("GUARD_DESIGN.md", "MEDIK8S_COMPARISON.md",
                     "CNPG_COMPARISON.md", "FIS_AZ_GAMEDAY.md",
                     "DR_REGION.md", "COST.md",
                     "adr/0007-node-down-guard.md"):
            self.assertTrue((ROOT / "docs" / name).exists(), name)
        # No ceiling bracket may leak into the README: every
        # number there must already be measured.
        readme = (ROOT / "README.md").read_text()
        self.assertNotIn("[N]", readme)
        self.assertNotIn("[X", readme)

    def test_ci_has_iac_scanning(self):
        ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
        self.assertIn("checkov", ci)
        self.assertIn("tflint", ci)
        drill = (ROOT / ".github" / "workflows" / "node-failure-drill.yml").read_text()
        self.assertIn("guard_chaos_test.sh", drill)


if __name__ == "__main__":
    unittest.main()
