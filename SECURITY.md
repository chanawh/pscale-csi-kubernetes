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
