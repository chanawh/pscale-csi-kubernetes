# FIS AZ game day (EKS)

Simulate the loss of one Availability Zone for the EKS node
group and measure what happens to the Postgres StatefulSet.
This is the game day the ceiling README calls for. It has
never been run: the Terraform below is validated only, and
there is no AWS account in this environment.

## The scenario, named

There is no single built-in FIS "AZ failure" action. The
scenario used here is the one the EKS Workshop documents:
FIS calls SSM automation with the public Resilience Hub
document `AWSResilienceHub-SimulateAzOutageInAsgTest_2020-07-23`
against the node group's Auto Scaling Group. The document
stops the ASG's instances in one AZ for the test duration,
then rolls back. The Terraform module (`terraform/fis/`)
builds exactly that template.

The DIY alternative is `terraform/fis/templates/diy-az-loss.json`:
compose the same outage by hand from `aws:network:disrupt-connectivity`
(block the AZ's subnets) plus `aws:ec2:stop-instances` (stop the
AZ's instances), both filtered by AZ. Use it if the SSM
document's behavior does not fit — for example, if you want
network isolation without stopping instances, or a longer
outage than the document allows. Fill in every `<...>`
placeholder before creating the template.

## Before the run

1. The EKS one-day run must have happened first
   (`docs/REAL_EKS_ONE_DAY.md`): a cluster, a node group
   with instances in at least 2 AZs, Postgres on EBS, and
   the row written.
2. The Postgres pod must be on an EBS volume in the AZ you
   are about to lose. EBS is AZ-bound: the volume cannot
   attach in another AZ, so the expected outcome is that the
   pod does NOT recover in the surviving AZ. The guard cannot
   fix this either — it can only taint and reschedule within
   the AZ. If the pod does recover elsewhere, something is
   wrong with the setup (the volume is EFS, not EBS).
   The point of the game day is to confirm that expectation
   and measure the client-visible outage, not to be surprised
   by it.
3. Stop conditions: at least one CloudWatch alarm. The
   template takes `canary_alarm_name` — the SLO burn-rate
   alarm from `monitoring/prometheus/csi-alerts.yaml`
   (exported to CloudWatch) or a simple error-rate alarm on
   the test client. An experiment with no stop condition is
   an experiment that cannot stop itself. Do not run the
   first game day without one.
4. Know the rollback: the SSM document rolls back on its own
   when the test duration ends (instances restart, ASG
   restores desired capacity). For the DIY template, rollback
   is manual: start the stopped instances, remove the network
   disruption. The FIS safety lever (`aws fis get-safety-lever
   --id default`) stops everything at once if the alarms do
   not.

## Run

```sh
cd terraform/fis
terraform init
terraform apply -var nodegroup_asg_name=<asg> -var canary_alarm_name=<alarm>
TEMPLATE=$(terraform output -raw experiment_template_id)
T0=$(date +%s)
aws fis start-experiment --experiment-template-id "$TEMPLATE"
# Watch the Postgres pod and the read-write service from another shell.
# Record: when the pod goes NotReady, when (if) it recovers, and
# when the row reads back. The experiment log group
# /aws/fis/pscale-csi-az-loss holds the FIS-side record.
echo "AZ game day wall time: $(( $(date +%s) - T0 ))s"
```

## What to record (evidence/dr-az-gameday.json)

- AZ lost, instance count in it, Postgres node and AZ.
- Time from experiment start to pod NotReady.
- Whether the pod recovered, where, and when — or that it
  did not, as expected for EBS.
- Time from experiment end (rollback) to the row reading back.
- Zero lost committed transactions: the row must read back
  with the value written before the experiment. A missing or
  changed row is data loss, not a slow recovery.
- FIS cost: $0.10 per action-minute (one action, test
  duration in minutes) plus $5 if you request an experiment
  report. See docs/COST.md.

## Cost

A 10-minute single-action experiment is about $1.00 of FIS
charges, plus the EKS cluster cost for the day. The cluster
is the expensive part, not FIS.
