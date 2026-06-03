"""CDK app entrypoint for the Phase-1 agent host.

Three stacks: long-lived NetworkStack + IamStack, replaceable AgentHostStack. The
out-of-band values (the two SecureString ARNs, the CMK ARN, the audit log group, the
git host CIDR) come from CDK context (`-c key=value`) and default to synthesizable
placeholders so `cdk synth` / the tests run with no AWS account. See
docs/P1-provisioning.md for the real values.
"""

from __future__ import annotations

from pathlib import Path

from aws_cdk import App, Environment

from aspects import apply_security_aspects
from stacks.agent_host_stack import AgentHostStack
from stacks.egress_stack import EgressStack
from stacks.iam_stack import IamStack
from stacks.network_stack import NetworkStack

BOOTSTRAP = Path(__file__).parent / "bootstrap"


def build(app: App) -> None:
    ctx = app.node.try_get_context
    region = ctx("region") or "us-east-1"
    account = ctx("account") or "123456789012"
    env = Environment(account=account, region=region)

    # Placeholder ARNs keep synth/tests offline; override with -c on deploy.
    p = f"arn:aws:ssm:{region}:{account}:parameter"
    key_param = ctx("key_param_arn") or f"{p}/pwfg/anthropic-key"
    deploy_param = ctx("deploy_key_param_arn") or f"{p}/pwfg/git-deploy-key"
    _dummy_key = "00000000-0000-0000-0000-000000000000"
    cmk = ctx("cmk_arn") or f"arn:aws:kms:{region}:{account}:key/{_dummy_key}"
    audit = ctx("audit_log_group_arn") or f"arn:aws:logs:{region}:{account}:log-group:/pwfg/audit"
    # Egress FAILS CLOSED: with no -c git_cidr the SG gets no git egress rule at all
    # (rather than 0.0.0.0/0). An explicit 0.0.0.0/0 is rejected in NetworkStack.
    git_cidr = ctx("git_cidr") or ""

    net = NetworkStack(app, "PwfgNetwork", env=env, git_cidr=git_cidr)
    iam_stack = IamStack(
        app,
        "PwfgIam",
        env=env,
        key_param_arn=key_param,
        deploy_key_param_arn=deploy_param,
        cmk_arn=cmk,
        audit_log_group_arn=audit,
    )
    AgentHostStack(
        app,
        "PwfgAgentHost",
        env=env,
        vpc=net.vpc,
        instance_sg=net.instance_sg,
        role=iam_stack.role,
        cloud_init_path=BOOTSTRAP / "cloud-init.yaml",
    )
    # The box's only internet path: a domain-allowlist Squid forward proxy on a
    # separate public subnet. Attaches the IGW/public-subnet to the EXISTING VPC as
    # raw L1 so PwfgNetwork stays IGW/NAT-free; the agent-host SG gains exactly one
    # egress (3128 -> the Squid SG, a standalone SG-referenced rule), never 0.0.0.0/0.
    EgressStack(
        app,
        "PwfgEgress",
        env=env,
        vpc=net.vpc,
        instance_sg=net.instance_sg,
        squid_cloud_init_path=BOOTSTRAP / "squid-cloud-init.yaml",
    )

    # Aspects LAST so the IMDS hop-limit + cdk-nag also cover the Squid launch template.
    apply_security_aspects(app)


def main() -> None:
    app = App()
    build(app)
    app.synth()


if __name__ == "__main__":
    main()
