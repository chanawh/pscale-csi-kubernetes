# Final roadmap: from lab project to cloud-role candidate

This roadmap is the sequence that makes this project, and
its sibling NAS-to-AWS migration project, count in a
cloud-role application. It is written for Andrew Chan,
Technical Support Engineer II at Dell Technologies since
December 2018, escalation point for 150+ enterprise Dell
PowerScale (OneFS) environments and 1,400+ high-severity
incidents. Certifications: AWS Solutions Architect
Professional, CKA, Terraform Associate, RHCE, CCNA.

## Phase 1, publish the final form

1. Push both repos and the `v1.0.0` tags to GitHub.
2. Set repo description and topics. This repo:
   description "PowerScale CSI on Kubernetes, Postgres
   on OneFS PVC, snapshot, clone, expand, node-failure
   drills", topics `kubernetes`, `csi`, `powerscale`,
   `helm`, `terraform`.
3. Confirm CI green on the final commits.
4. Publish the GitHub profile README at `chanawh/chanawh`,
   linking this project, the migration project, the
   PowerScale Prometheus exporter, and powerscale-async.

## Phase 2, prove it live

5. Run this project on a real machine: OneFS Simulator
   in VMware Workstation Pro, kind, Dell's driver, four drills.
6. Run the migration project against LocalStack in Docker,
   then against the OneFS node with `--source-mode onefs`.
7. One-day real AWS run for the migration project, and
   optionally a one-day EKS run for this project,
   about $4.50 for a day, then destroy. Resume bullets
   count only after clean verifies there.
8. Save evidence from those runs. Evidence beats claims.

## Phase 3, use it to get interviews

9. STAR bullet from `docs/INTERVIEW_GUIDE.md` on the resume,
   labelled lab/emulator until Phase 2 is done.
10. Rehearse the 30-second pitch and the ten Q&As out loud, timed.
11. Apply to Cloud Support Engineer, Cloud Operations,
    Storage and Platform Engineer first, SRE second.
    No mass-applying, no third project.
12. AZ-104 in parallel, the cert gate for Azure-titled roles.

## What not to do

Do not build more projects. Do not call kind production.
Do not claim Dell's driver as your own. The driver is
Dell's, the operating, drills, and evidence are yours.
