# Contributing

This is a portfolio lab project, not a production service.
Contributions are welcome, but the bar is: prove it runs.

## Rules

- Run the checks before you open a PR: `python -m unittest discover -s python/tests -v`,
  `cd terraform && terraform fmt -check && terraform validate`,
  and `helm template` for the driver.
- Do not commit `helm/isilon-creds.yaml`, Terraform state,
  `.terraform/`, `__pycache__/`, or credentials.
- Do not claim kind results as production results. Lab
  limits stay labelled as lab limits.
- One change per PR. If you add a drill, add its script in
  `drills/`, its failure mode in `docs/SYSTEM_DESIGN.md`,
  and its test.
