#!/usr/bin/env python3
"""Measure the RPO of the CNPG cluster: WAL lag, in seconds and bytes.

Two RPOs, because the cluster has two ways to lose data:
  failover RPO — the standby replay lag at the kill. If the
    primary dies and the standby is promoted, the promoted
    standby is missing the transactions the primary wrote
    after the standby's replay point. This is the RPO for
    the failover the drills time.
  archive RPO — the WAL not yet archived to S3. If the
    primary dies AND its volume is gone, the recoverable
    point is the last archived WAL; everything after it is
    lost. This is the RPO for point-in-time recovery.

Both are measured from the live cluster (no guess):
  pg_current_wal_lsn() for where the primary is now,
  pg_stat_archiver for the last archived WAL and when it
  was archived, pg_stat_replication for each standby's
  replay point, and the Cluster status for
  lastArchivedWAL / firstRecoverabilityPoint.

Runs wherever there is a CNPG cluster and kubectl: on kind
(the archive is not configured there, so archive RPO is
recorded "not configured" and only the failover RPO is
measured) and on EKS (with the plugin + ObjectStore, both
are measured). Exit 0 when at least one RPO was measured,
exit 2 when nothing could be measured — the evidence file
is still written, with measured:false and the reason, never
a fake number. Stdlib only.

Usage:
  python3 scripts/drills/rpo_measure.py [--cluster NAME]
      [--namespace NS] [--evidence PATH]
"""
import argparse
import base64
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CLUSTER = "postgres-cnpg"
DEFAULT_NAMESPACE = "csi-demo"
WAL_SEGMENT_BYTES = 16 * 1024 * 1024  # 16 MiB, PostgreSQL default


def lsn_to_int(lsn):
    """A WAL LSN 'X/Y' (hex) as a byte offset in the WAL stream."""
    high, _, low = lsn.strip().partition("/")
    if not high or not low:
        raise ValueError("not an LSN: %r" % lsn)
    return (int(high, 16) << 32) + int(low, 16)


def wal_file_end_lsn(filename):
    """End LSN of a WAL file name (24 hex chars: timeline/logid/segment).

    The LSN is (logid << 32) | byte-offset-in-log; each log is
    2**32 bytes, split into 16 MiB segments, so the file's end is
    its segment start plus one segment. The timeline is not part
    of the LSN and is ignored.
    """
    name = filename.strip()
    if len(name) != 24 or any(c not in "0123456789abcdefABCDEF" for c in name):
        raise ValueError("not a WAL file name: %r" % filename)
    logid = int(name[8:16], 16)
    segno = int(name[16:24], 16)
    return (logid << 32) + (segno + 1) * WAL_SEGMENT_BYTES


def parse_interval(text):
    """A Postgres interval ('HH:MM:SS[.ffffff]', optionally with
    'N day(s)') as seconds, or None when empty."""
    text = (text or "").strip()
    if not text:
        return None
    days = 0
    if "day" in text:
        days_part, _, rest = text.partition("day")
        days = int(days_part.strip())
        text = rest.lstrip("s").strip()
    parts = text.split(":")
    if len(parts) != 3:
        raise ValueError("not an interval: %r" % text)
    hours, minutes, seconds = (float(p) for p in parts)
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def parse_timestamp(text):
    """A timestamptz ('YYYY-MM-DD HH:MM:SS.ffffff+00') as an aware
    datetime, or None when empty."""
    text = (text or "").strip()
    if not text:
        return None
    return datetime.fromisoformat(text)


def compute_archive_lag(current_lsn, last_archived_wal, last_archived_time, now):
    """Archive RPO from the archiver state, or None when the
    archive is not configured (no WAL archived yet)."""
    if not last_archived_wal:
        return None
    end = wal_file_end_lsn(last_archived_wal)
    lag_bytes = max(0, lsn_to_int(current_lsn) - end)
    lag_seconds = None
    archived_at = parse_timestamp(last_archived_time)
    if archived_at is not None:
        lag_seconds = max(0.0, (now - archived_at).total_seconds())
    return {
        "configured": True,
        "lag_bytes": lag_bytes,
        "lag_seconds": lag_seconds,
        "last_archived_wal": last_archived_wal,
        "last_archived_time": last_archived_time or None,
    }


def compute_standby_lag(current_lsn, rows):
    """Failover RPO from pg_stat_replication rows (one dict per
    standby: application_name, replay_lsn, replay_lag). Returns
    None when no standby is streaming."""
    current = lsn_to_int(current_lsn)
    standbys = []
    for row in rows:
        replay_lsn = (row.get("replay_lsn") or "").strip()
        if not replay_lsn:
            continue
        lag_bytes = max(0, current - lsn_to_int(replay_lsn))
        lag_seconds = parse_interval(row.get("replay_lag"))
        standbys.append({
            "application_name": row.get("application_name") or None,
            "replay_lsn": replay_lsn,
            "replay_lag_seconds": lag_seconds,
            "replay_lag_bytes": lag_bytes,
        })
    if not standbys:
        return None
    byte_lags = [s["replay_lag_bytes"] for s in standbys]
    sec_lags = [s["replay_lag_seconds"] for s in standbys
                if s["replay_lag_seconds"] is not None]
    return {
        "measured": True,
        "standbys": standbys,
        "max_lag_bytes": max(byte_lags),
        "min_lag_bytes": min(byte_lags),
        "max_lag_seconds": max(sec_lags) if sec_lags else None,
        "min_lag_seconds": min(sec_lags) if sec_lags else None,
    }


def run(cmd, runner):
    """Run a command through the runner; (returncode, stdout, stderr)."""
    return runner(cmd)


def psql(runner, kubectl, namespace, password, sql, tag):
    """One-shot psql pod against the read-write service, like the
    drill scripts: postgres:16, --restart=Never, PGPASSWORD from
    the bootstrap secret, PGCONNECT_TIMEOUT so a dead endpoint
    fails fast instead of hanging. Returns stdout, or raises
    RuntimeError when the pod fails."""
    pod = "rpo-psql-%s-%d" % (
        datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S"),
        os.getpid(),
    )
    cmd = [
        kubectl, "-n", namespace, "run", pod, "--rm", "-i",
        "--restart=Never", "--image=postgres:16",
        "--env", "PGPASSWORD=%s" % password,
        "--env", "PGCONNECT_TIMEOUT=10", "--",
        "psql", "-h", "postgres-cnpg-rw", "-U", "postgres",
        "-d", "csi_demo", "-tAc", sql,
    ]
    rc, out, err = run(cmd, runner)
    if rc != 0:
        raise RuntimeError("psql %s failed: %s" % (tag, err.strip()))
    return out


def measure(runner, kubectl, cluster, namespace, now):
    """Measure both RPOs. Returns (evidence dict, exit code)."""
    evidence = {
        "scope": "CNPG cluster WAL / replication lag (kind or EKS); "
                 "the RPO numbers, not a backup restore test",
        "cluster": cluster,
        "namespace": namespace,
        "measured": False,
        "reason": None,
        "archive_rpo": {"configured": False},
        "failover_rpo": {"measured": False},
        "rpo_definition": "failover RPO = standby replay lag at the "
            "kill (worst standby); archive RPO = WAL not yet archived "
            "(recoverable only from the primary/standby)",
    }
    rc, out, _err = run(
        [kubectl, "-n", namespace, "get", "cluster", cluster, "-o", "json"],
        runner,
    )
    if rc != 0 or not out.strip():
        evidence["reason"] = "cluster %s not found in namespace %s" % (
            cluster, namespace)
        return evidence, 2
    try:
        status = json.loads(out).get("status") or {}
    except json.JSONDecodeError:
        evidence["reason"] = "cluster %s returned unparseable JSON" % cluster
        return evidence, 2
    evidence["cluster_phase"] = status.get("phase")
    evidence["current_primary"] = status.get("currentPrimary")
    evidence["first_recoverability_point"] = status.get(
        "firstRecoverabilityPoint")
    evidence["last_archived_wal"] = status.get("lastArchivedWAL")
    evidence["last_archived_wal_time"] = status.get("lastArchivedWALTime")

    rc, out, _err = run(
        [kubectl, "-n", namespace, "get", "secret", "postgres-cnpg-secret",
         "-o", "jsonpath={.data.password}"],
        runner,
    )
    if rc != 0 or not out.strip():
        evidence["reason"] = "cannot read the bootstrap secret " \
            "postgres-cnpg-secret"
        return evidence, 2
    try:
        password = base64.b64decode(out.strip()).decode()
    except Exception:
        evidence["reason"] = "bootstrap secret password is not base64"
        return evidence, 2

    try:
        current_lsn = psql(
            runner, kubectl, namespace, password,
            "SELECT pg_current_wal_lsn();", "current LSN").strip()
        archiver = psql(
            runner, kubectl, namespace, password,
            "SELECT COALESCE(last_archived_wal, ''), "
            "COALESCE(last_archived_time::text, '') "
            "FROM pg_stat_archiver;", "archiver").strip()
        replication = psql(
            runner, kubectl, namespace, password,
            "SELECT application_name, COALESCE(replay_lsn::text, ''), "
            "COALESCE(replay_lag::text, '') FROM pg_stat_replication;",
            "replication").strip()
    except RuntimeError as exc:
        evidence["reason"] = str(exc)
        return evidence, 2

    evidence["current_wal_lsn"] = current_lsn
    last_wal, _, last_time = archiver.partition("|")
    archive = compute_archive_lag(
        current_lsn, last_wal.strip(), last_time.strip(), now)
    if archive is not None:
        evidence["archive_rpo"] = archive
    rows = []
    for line in replication.splitlines():
        if not line.strip():
            continue
        fields = line.split("|")
        rows.append({
            "application_name": fields[0] if len(fields) > 0 else "",
            "replay_lsn": fields[1] if len(fields) > 1 else "",
            "replay_lag": fields[2] if len(fields) > 2 else "",
        })
    standby = compute_standby_lag(current_lsn, rows)
    if standby is not None:
        evidence["failover_rpo"] = standby

    measured = (evidence["archive_rpo"].get("configured") is True
                or evidence["failover_rpo"].get("measured") is True)
    evidence["measured"] = measured
    if not measured:
        evidence["reason"] = "no standby streaming and no WAL archived"
        return evidence, 2
    return evidence, 0


def default_runner(cmd):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as exc:
        # kubectl (or the binary) is not installed: report it as a
        # failed command, not a traceback — measure() records it
        # as "not measured" with the reason.
        return 127, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Measure the CNPG cluster RPO (WAL lag).")
    parser.add_argument("--cluster", default=DEFAULT_CLUSTER)
    parser.add_argument("--namespace", default=DEFAULT_NAMESPACE)
    parser.add_argument("--kubectl", default="kubectl")
    parser.add_argument("--evidence", default=None)
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)
    evidence_path = Path(args.evidence) if args.evidence else (
        ROOT / "evidence" / ("rpo-%s.json" % now.strftime("%Y-%m-%d")))
    evidence, code = measure(
        default_runner, args.kubectl, args.cluster, args.namespace, now)
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    with open(evidence_path, "w") as f:
        json.dump(evidence, f, indent=2)
    print(open(evidence_path).read())
    print("evidence written to %s" % evidence_path)
    return code


if __name__ == "__main__":
    sys.exit(main())
