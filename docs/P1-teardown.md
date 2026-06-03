# Phase 1 — shutting down the dev boxes

How to tear down a Phase-1 test deployment when you are done. The default is a **full
`cdk destroy`** — the boxes are disposable and the recurring cost (the interface
endpoints alone are ~$30/mo) is not worth leaving up between tests.

Two stacks hold instances (`PwfgAgentHost`, `PwfgEgress`); two are long-lived
(`PwfgNetwork`, `PwfgIam`). Destroy in **reverse dependency order** — `PwfgEgress`
imports the agent-host security group from `PwfgNetwork`, so that export is locked
until Egress is gone.

## Option A — full teardown (recommended after a test)

```
cd infra
# Reverse order. Pass the SAME -c context you deployed with (CDK needs it to look up
# the stacks); --force skips the per-stack y/n prompt.
npx cdk@2 destroy --force \
  PwfgEgress PwfgAgentHost PwfgIam PwfgNetwork \
  -c account=<acct> -c region=<region> \
  -c key_param_arn=<arn> -c deploy_key_param_arn=<arn> \
  -c cmk_arn=<arn> -c audit_log_group_arn=<arn>
```

This terminates both instances (EBS volumes are `delete_on_termination=True`), removes
the IGW + public subnet + route tables, the VPC + the four interface endpoints + the S3
gateway endpoint, the security groups, the IAM role, and the flow-log group the VPC
created. Termination protection is off by design, so nothing blocks the destroy.

If `cdk` is unavailable, delete the CloudFormation stacks in the same order from the
console (CloudFormation → select stack → Delete), or:

```
for s in PwfgEgress PwfgAgentHost PwfgIam PwfgNetwork; do
  aws cloudformation delete-stack --stack-name "$s" --region <region>
  aws cloudformation wait stack-delete-complete --stack-name "$s" --region <region>
done
```

## What `cdk destroy` does NOT remove (out-of-band; delete by hand if you want)

These are created out of band and only referenced by ARN, so the stacks never owned
them. Keep them to re-test cheaply, or delete to leave nothing behind:

| Resource | Keep for re-test? | Delete command |
|---|---|---|
| SSM SecureString `pwfg/anthropic-key` | usually keep | `aws ssm delete-parameter --name pwfg/anthropic-key` |
| SSM SecureString `pwfg/git-deploy-key` | usually keep | `aws ssm delete-parameter --name pwfg/git-deploy-key` |
| KMS CMK (`alias/pwfg`) | keep (deletion is a 7–30 day scheduled window) | `aws kms schedule-key-deletion --key-id <id> --pending-window-in-days 7` |
| CloudWatch log group `/pwfg/audit` | optional | `aws logs delete-log-group --log-group-name /pwfg/audit` |
| S3 artifact bucket (if you added one for code delivery) | optional | empty it, then `aws s3 rb s3://<bucket> --force` |

**Rotate the Anthropic key** if the test exposed it in any way you are unsure about —
it is the one real secret in play.

## Option B — stop, but keep the stacks (only for a quick re-test)

Stopping the instances halts compute billing but **leaves the four interface endpoints
running (~$30/mo)** plus the EBS volumes and the Squid public IPv4 — so this is only
worth it for a re-test within a day or two. Prefer Option A otherwise.

```
ids=$(aws ec2 describe-instances --region <region> \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=PwfgAgentHost,PwfgEgress" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ec2 stop-instances --region <region> --instance-ids $ids
```

Note: `/run/pwfg/anthropic_key` is on tmpfs, so it is wiped on stop and re-fetched from
SSM by `pwfg-key-fetch.service` on the next start — no manual key step needed to resume.

## Verify everything is down (and not billing)

```
# No running/stopped pwfg instances:
aws ec2 describe-instances --region <region> \
  --filters "Name=tag:aws:cloudformation:stack-name,Values=PwfgAgentHost,PwfgEgress" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output text

# The VPC (and its endpoints) are gone:
aws ec2 describe-vpcs --region <region> --filters "Name=tag:Name,Values=*Pwfg*" \
  --query 'Vpcs[].VpcId' --output text
aws ec2 describe-vpc-endpoints --region <region> \
  --query 'VpcEndpoints[].VpcEndpointId' --output text

# No leftover Elastic IPs (only relevant if you switched Squid to an EIP):
aws ec2 describe-addresses --region <region> --query 'Addresses[].PublicIp' --output text
```

A clean run prints empty results for the VPC/endpoint queries and nothing in
`running`/`stopped` for the instances.

## Order rationale (why reverse)

- `PwfgEgress` → first: it imports `PwfgNetwork`'s instance-SG id (the standalone
  SG-referenced egress rule that keeps the agent host off `0.0.0.0/0`), which locks that
  export while Egress exists.
- `PwfgAgentHost` → next: the replaceable box.
- `PwfgIam`, `PwfgNetwork` → last: the long-lived role + network.

Deploy order is the mirror (`Network → Iam → AgentHost → Egress`); see
`P1-provisioning.md`.
