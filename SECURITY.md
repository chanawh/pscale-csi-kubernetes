# Security

## Reporting

This is a lab project. If you find a security issue, open
an issue in the repo. Do not include credentials in the report.

## What is safe here

- No real credentials are committed. `helm/isilon-creds.yaml`
  is gitignored. Only `helm/isilon-creds.yaml.example`
  is committed, and it holds `CHANGE-ME`, not a password.
- The Postgres password in `k8s/postgres-secret.yaml`
  is `postgres`, a lab placeholder, stated as such.
  Change it before any real use.
- The driver secret is created before Helm install, so
  the controller does not start without credentials.
- On EKS, the EBS and EFS CSI controllers each get a
  dedicated least-privilege IAM role via EKS Pod
  Identity, bound to one namespace + service account.
  No storage permissions on the node role.
- EKS Secrets are envelope-encrypted with a KMS key
  (`encryption_config` in `terraform/eks.tf`), and EFS
  is encrypted at rest with mount targets accepting
  NFS only from the VPC CIDR.

## What is not safe, and is labelled as such

- `skipCertificateValidation: true` in `helm/values.yaml`
  is lab-only, because the OneFS Simulator uses a
  self-signed cert. On a real cluster, set it false
  and provide `isilon-cert-0`.
- Using `root` for the driver is lab-only. On a real
  cluster, create a dedicated OneFS user with the
  minimum roles the driver needs.
- kind is a lab cluster. It is not hardened, and it is
  not a production topology.
- The EKS Terraform uses the default VPC. That is a lab
  shortcut, not a production network design.
- The Grafana admin password in
  `helm/observability-values.yaml` is a lab placeholder
  (`lab-only-change-me`), Grafana is ClusterIP-only, and
  the EKS API endpoint is public in the lab config.
  Change all three before any real use.
- The EFS filesystem ID in
  `k8s/eks/storageclass-efs.yaml` is a placeholder
  substituted at deploy time. A real filesystem ID must
  never be committed, same rule as the OneFS creds file.
