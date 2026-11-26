"""Unit tests for the RPO measurement (scripts/drills/rpo_measure.py).

No cluster, no kubectl, no psql: a fake runner answers the
kubectl and psql calls with canned output, so the LSN math,
the lag computation, and the not-measured paths are tested
without a cluster. Run with:
  python -m unittest discover -s python/tests -v
"""
import base64
import json
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "drills"))
import rpo_measure  # noqa: E402


def dt(text):
    return datetime.fromisoformat(text)


class FakeRunner:
    """Answers commands by substring; records every call."""

    def __init__(self, answers):
        # answers: list of (substring, (rc, stdout, stderr))
        self.answers = answers
        self.calls = []

    def __call__(self, cmd):
        joined = " ".join(cmd)
        self.calls.append(joined)
        for needle, result in self.answers:
            if needle in joined:
                return result
        return 1, "", "unexpected command: %s" % joined


CLUSTER_JSON = json.dumps({
    "status": {
        "phase": "Cluster in healthy state",
        "currentPrimary": "postgres-cnpg-1",
        "lastArchivedWAL": "00000001000000000000000A",
        "lastArchivedWALTime": "2026-11-26T08:00:00Z",
        "firstRecoverabilityPoint": "2026-11-26T07:00:00Z",
    }
})


def healthy_answers():
    return [
        ("get cluster", (0, CLUSTER_JSON, "")),
        ("get secret", (0, base64.b64encode(b"postgres").decode(), "")),
        ("pg_current_wal_lsn", (0, "0/3000000\n", "")),
        ("pg_stat_archiver",
         (0, "000000010000000000000001|2026-11-26 08:00:00+00\n", "")),
        ("pg_stat_replication",
         (0, "postgres-cnpg-2|0/2000000|00:00:00.5\n", "")),
    ]


class TestLsnMath(unittest.TestCase):
    def test_lsn_to_int(self):
        self.assertEqual(rpo_measure.lsn_to_int("0/0"), 0)
        self.assertEqual(rpo_measure.lsn_to_int("0/1000000"), 16777216)
        self.assertEqual(rpo_measure.lsn_to_int("1/0"), 4294967296)
        self.assertEqual(
            rpo_measure.lsn_to_int("0/16B1978"), int("16B1978", 16))

    def test_lsn_bad_input(self):
        for bad in ("", "no-slash", "0/", "/1", "zz/1"):
            with self.assertRaises(ValueError, msg=bad):
                rpo_measure.lsn_to_int(bad)

    def test_wal_file_end_lsn(self):
        # segno 0xA: end is segment 11 of log 0.
        self.assertEqual(
            rpo_measure.wal_file_end_lsn("00000001000000000000000A"),
            11 * 16 * 1024 * 1024)
        # logid 1, segno 0: end is the first segment of log 1.
        self.assertEqual(
            rpo_measure.wal_file_end_lsn("000000010000000100000000"),
            (1 << 32) + 16 * 1024 * 1024)

    def test_wal_file_bad_input(self):
        for bad in ("", "short", "00000001000000000000000G"):
            with self.assertRaises(ValueError, msg=bad):
                rpo_measure.wal_file_end_lsn(bad)


class TestIntervalsAndTimestamps(unittest.TestCase):
    def test_parse_interval(self):
        self.assertEqual(rpo_measure.parse_interval("00:00:01.5"), 1.5)
        self.assertEqual(rpo_measure.parse_interval("00:01:00"), 60.0)
        self.assertEqual(rpo_measure.parse_interval("01:00:00"), 3600.0)
        self.assertEqual(rpo_measure.parse_interval("1 day 00:00:00"),
                         86400.0)
        self.assertIsNone(rpo_measure.parse_interval(""))
        self.assertIsNone(rpo_measure.parse_interval(None))

    def test_parse_timestamp(self):
        parsed = rpo_measure.parse_timestamp("2026-11-26 08:00:00+00")
        self.assertEqual(parsed, dt("2026-11-26T08:00:00+00:00"))
        self.assertIsNotNone(parsed.tzinfo)
        self.assertIsNone(rpo_measure.parse_timestamp(""))
        self.assertIsNone(rpo_measure.parse_timestamp(None))


class TestLagComputation(unittest.TestCase):
    def test_archive_lag(self):
        now = dt("2026-11-26T08:00:10+00:00")
        lag = rpo_measure.compute_archive_lag(
            "0/3000000", "000000010000000000000001",
            "2026-11-26 08:00:00+00", now)
        # current 0x3000000 (48 MiB) minus end of segment 1 (32 MiB).
        self.assertEqual(lag["lag_bytes"], 16 * 1024 * 1024)
        self.assertEqual(lag["lag_seconds"], 10.0)
        self.assertTrue(lag["configured"])

    def test_archive_lag_not_configured(self):
        now = dt("2026-11-26T08:00:10+00:00")
        self.assertIsNone(rpo_measure.compute_archive_lag(
            "0/3000000", "", "", now))

    def test_archive_lag_never_negative(self):
        # Current LSN behind the archived end (timeline switch):
        # clamp to zero, do not report a negative lag.
        now = dt("2026-11-26T08:00:10+00:00")
        lag = rpo_measure.compute_archive_lag(
            "0/1000000", "00000001000000000000000A",
            "2026-11-26 08:00:00+00", now)
        self.assertEqual(lag["lag_bytes"], 0)

    def test_standby_lag(self):
        lag = rpo_measure.compute_standby_lag("0/3000000", [
            {"application_name": "postgres-cnpg-2",
             "replay_lsn": "0/2000000", "replay_lag": "00:00:00.5"},
            {"application_name": "postgres-cnpg-3",
             "replay_lsn": "0/2800000", "replay_lag": "00:00:00.1"},
        ])
        self.assertTrue(lag["measured"])
        self.assertEqual(len(lag["standbys"]), 2)
        # Worst standby is the 0/2000000 one (16 MiB behind).
        self.assertEqual(lag["max_lag_bytes"], 16 * 1024 * 1024)
        self.assertEqual(lag["min_lag_bytes"], 8 * 1024 * 1024)
        self.assertEqual(lag["max_lag_seconds"], 0.5)
        self.assertEqual(lag["min_lag_seconds"], 0.1)

    def test_standby_lag_no_standby(self):
        self.assertIsNone(rpo_measure.compute_standby_lag("0/3000000", []))
        # A standby row with no replay point is skipped.
        self.assertIsNone(rpo_measure.compute_standby_lag("0/3000000", [
            {"application_name": "x", "replay_lsn": "",
             "replay_lag": ""}]))


class TestMeasure(unittest.TestCase):
    def setUp(self):
        self.now = dt("2026-11-26T08:00:10+00:00")

    def measure(self, answers):
        runner = FakeRunner(answers)
        evidence, code = rpo_measure.measure(
            runner, "kubectl", "postgres-cnpg", "csi-demo", self.now)
        return runner, evidence, code

    def test_healthy_cluster(self):
        runner, evidence, code = self.measure(healthy_answers())
        self.assertEqual(code, 0)
        self.assertTrue(evidence["measured"])
        self.assertEqual(evidence["current_wal_lsn"], "0/3000000")
        self.assertEqual(evidence["current_primary"], "postgres-cnpg-1")
        self.assertEqual(
            evidence["first_recoverability_point"],
            "2026-11-26T07:00:00Z")
        self.assertTrue(evidence["archive_rpo"]["configured"])
        self.assertEqual(evidence["archive_rpo"]["lag_bytes"],
                         16 * 1024 * 1024)
        self.assertEqual(evidence["archive_rpo"]["lag_seconds"], 10.0)
        self.assertTrue(evidence["failover_rpo"]["measured"])
        self.assertEqual(evidence["failover_rpo"]["max_lag_bytes"],
                         16 * 1024 * 1024)
        # The psql pod uses the read-write service, --restart=Never,
        # and the postgres:16 image, like the drill scripts.
        psql_calls = [c for c in runner.calls if "psql" in c]
        self.assertEqual(len(psql_calls), 3)
        for call in psql_calls:
            self.assertIn("postgres-cnpg-rw", call)
            self.assertIn("--restart=Never", call)
            self.assertIn("--image=postgres:16", call)

    def test_cluster_not_found(self):
        runner, evidence, code = self.measure([
            ("get cluster", (1, "", "NotFound")),
        ])
        self.assertEqual(code, 2)
        self.assertFalse(evidence["measured"])
        self.assertIn("not found", evidence["reason"])

    def test_no_archive_configured(self):
        answers = healthy_answers()
        answers[3] = ("pg_stat_archiver", (0, "|\n", ""))
        runner, evidence, code = self.measure(answers)
        self.assertEqual(code, 0)
        self.assertTrue(evidence["measured"])
        self.assertFalse(evidence["archive_rpo"]["configured"])
        self.assertTrue(evidence["failover_rpo"]["measured"])

    def test_no_standby_streaming(self):
        answers = healthy_answers()
        answers[4] = ("pg_stat_replication", (0, "\n", ""))
        runner, evidence, code = self.measure(answers)
        self.assertEqual(code, 0)
        self.assertTrue(evidence["measured"])
        self.assertTrue(evidence["archive_rpo"]["configured"])
        self.assertFalse(evidence["failover_rpo"]["measured"])

    def test_nothing_measurable(self):
        answers = healthy_answers()
        answers[3] = ("pg_stat_archiver", (0, "|\n", ""))
        answers[4] = ("pg_stat_replication", (0, "\n", ""))
        runner, evidence, code = self.measure(answers)
        self.assertEqual(code, 2)
        self.assertFalse(evidence["measured"])
        self.assertIsNotNone(evidence["reason"])

    def test_psql_fails(self):
        answers = healthy_answers()
        answers[2] = ("pg_current_wal_lsn",
                      (1, "", "connection refused"))
        runner, evidence, code = self.measure(answers)
        self.assertEqual(code, 2)
        self.assertFalse(evidence["measured"])
        self.assertIn("psql", evidence["reason"])


if __name__ == "__main__":
    unittest.main()
