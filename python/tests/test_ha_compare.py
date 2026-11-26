"""Unit tests for the HA comparison (scripts/drills/ha_compare.py).

No cluster, no drills: the comparison is a pure function of
evidence files, so the tests feed it sample evidence dicts
and check the table it builds — including the arms that did
not run. Run with:
  python -m unittest discover -s python/tests -v
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "drills"))
import ha_compare  # noqa: E402


CNPG = {
    "median_serving_seconds": 45,
    "failover_trials": [
        {"trial": 1, "kill_to_ready_seconds": 30,
         "kill_to_serving_seconds": 40, "row_intact": True,
         "failed": False},
        {"trial": 2, "kill_to_ready_seconds": 35,
         "kill_to_serving_seconds": 45, "row_intact": True,
         "failed": False},
        {"trial": 3, "kill_to_ready_seconds": 40,
         "kill_to_serving_seconds": 50, "row_intact": True,
         "failed": False},
    ],
}

SINGLE = {
    "completed": True,
    "cases": {
        "hard_stop_out_of_service_taint": {
            "ready_seconds": 195, "serving_seconds": 198,
        },
    },
}

GUARD = {
    "live_guard_median_serving_seconds": 300,
    "live_guard_trials": [
        {"trial": 1, "kill_to_ready_seconds": 280,
         "kill_to_serving_seconds": 290},
        {"trial": 2, "kill_to_ready_seconds": 295,
         "kill_to_serving_seconds": 305},
        {"trial": 3, "kill_to_ready_seconds": 300,
         "kill_to_serving_seconds": 310},
    ],
    "refusal_trials": [
        {"trial": 1, "refused": True},
        {"trial": 2, "refused": True},
        {"trial": 3, "refused": True},
    ],
}

RPO = {
    "measured": True,
    "failover_rpo": {"measured": True, "max_lag_seconds": 0.5,
                     "max_lag_bytes": 1024},
    "archive_rpo": {"configured": False},
}


class TestMedian(unittest.TestCase):
    def test_median(self):
        self.assertEqual(ha_compare.median([5, 198, 10]), 10)
        self.assertEqual(ha_compare.median([45]), 45)
        self.assertIsNone(ha_compare.median([]))
        # None entries are ignored, not counted.
        self.assertEqual(ha_compare.median([None, 5, None]), 5)
        self.assertIsNone(ha_compare.median([None, None]))


class TestLoadJson(unittest.TestCase):
    def test_missing_file_is_none(self):
        self.assertIsNone(ha_compare.load_json(None))
        self.assertIsNone(ha_compare.load_json("/nonexistent/x.json"))

    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "e.json"
            path.write_text(json.dumps({"a": 1}))
            self.assertEqual(ha_compare.load_json(path), {"a": 1})


class TestBuildComparison(unittest.TestCase):
    def test_full_comparison(self):
        comparison = ha_compare.build_comparison(
            CNPG, SINGLE, GUARD, RPO, "kind + NFS")
        self.assertEqual(comparison["scope"], "kind + NFS")
        cnpg = comparison["arms"]["cnpg_ha"]
        self.assertTrue(cnpg["measured"])
        self.assertEqual(cnpg["median_serving_seconds"], 45)
        self.assertEqual(cnpg["median_ready_seconds"], 35)
        self.assertEqual(cnpg["trials"], 3)
        self.assertEqual(cnpg["failed_trials"], 0)
        self.assertTrue(cnpg["row_intact"])
        single = comparison["arms"]["single_replica_manual_taint"]
        self.assertTrue(single["measured"])
        self.assertEqual(single["median_serving_seconds"], 198)
        self.assertEqual(single["median_ready_seconds"], 195)
        guard = comparison["arms"]["single_replica_guard"]
        self.assertTrue(guard["measured"])
        self.assertEqual(guard["median_serving_seconds"], 300)
        self.assertEqual(guard["refusals"], {"refused": 3, "of": 3})
        self.assertTrue(comparison["rpo"]["measured"])
        self.assertEqual(
            comparison["rpo"]["failover_rpo_max_lag_seconds"], 0.5)
        self.assertFalse(comparison["rpo"]["archive_rpo_configured"])
        # CNPG is fastest; the deltas are against it.
        self.assertEqual(comparison["fastest"], "cnpg_ha")
        self.assertEqual(comparison["deltas_seconds"], {
            "cnpg_ha": 0,
            "single_replica_manual_taint": 153,
            "single_replica_guard": 255,
        })

    def test_missing_guard_is_not_measured(self):
        comparison = ha_compare.build_comparison(
            CNPG, SINGLE, None, RPO, "kind + NFS")
        guard = comparison["arms"]["single_replica_guard"]
        self.assertFalse(guard["measured"])
        self.assertIn("guard-live", guard["reason"])
        # The comparison still builds from the arms that ran.
        self.assertEqual(comparison["fastest"], "cnpg_ha")

    def test_failed_cnpg_arm(self):
        failed = {
            "median_serving_seconds": None,
            "failover_trials": [
                {"trial": 1, "kill_to_serving_seconds": None,
                 "row_intact": None, "failed": True},
            ],
        }
        comparison = ha_compare.build_comparison(
            failed, SINGLE, GUARD, RPO, "kind + NFS")
        cnpg = comparison["arms"]["cnpg_ha"]
        self.assertFalse(cnpg["measured"])
        self.assertEqual(cnpg["failed_trials"], 1)
        self.assertEqual(comparison["fastest"],
                         "single_replica_manual_taint")

    def test_missing_single_arm(self):
        comparison = ha_compare.build_comparison(
            CNPG, None, GUARD, RPO, "kind + NFS")
        single = comparison["arms"]["single_replica_manual_taint"]
        self.assertFalse(single["measured"])
        self.assertIn("node-failure-drill", single["reason"])

    def test_nothing_measured(self):
        comparison = ha_compare.build_comparison(
            None, None, None, None, "kind + NFS")
        self.assertIsNone(comparison["fastest"])
        self.assertEqual(comparison["deltas_seconds"], {})
        for arm in comparison["arms"].values():
            self.assertFalse(arm["measured"])
        self.assertFalse(comparison["rpo"]["measured"])

    def test_write_evidence(self):
        comparison = ha_compare.build_comparison(
            CNPG, SINGLE, GUARD, RPO, "kind + NFS")
        with tempfile.TemporaryDirectory() as tmp:
            path = ha_compare.write_evidence(
                comparison, Path(tmp) / "ha.json")
            self.assertEqual(json.loads(path.read_text()), comparison)


if __name__ == "__main__":
    unittest.main()
