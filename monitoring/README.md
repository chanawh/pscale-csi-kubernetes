# Monitoring as code

Grafana dashboard and Prometheus alerts for the CSI demo,
built as code and validated in CI (JSON/YAML parse, panel
and alert counts, non-empty expressions). Not yet applied
to a live cluster from this build environment - they load
with the observability stack on the EKS one-day run, or on
kind with kube-prometheus-stack installed.

| File | What it is |
|---|---|
| `grafana/csi-storage-dashboard.json` | 8-panel dashboard: PVC phase, requested vs used bytes, Postgres restarts, pod readiness (drain drill), node CPU/memory, CSI controller pods, snapshot readiness |
| `prometheus/csi-alerts.yaml` | PrometheusRule with 5 alerts: PVC pending, PVC over 85% full, Postgres pod not ready, CSI controller down, snapshot not ready |

Load on EKS (after `scripts/eks/deploy_eks.sh`):

```sh
kubectl apply -f monitoring/prometheus/csi-alerts.yaml
# Grafana: import monitoring/grafana/csi-storage-dashboard.json
# (Dashboards > Import), datasource Prometheus.
```

The `release: observability` label on the PrometheusRule
matches the kube-prometheus-stack release name used by
`scripts/eks/deploy_eks.sh`, so the operator picks it up
without extra selector config.
