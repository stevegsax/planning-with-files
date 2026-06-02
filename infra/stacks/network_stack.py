"""NetworkStack — the long-lived, isolated network for the agent host.

A 1-AZ VPC with a single PRIVATE_ISOLATED subnet: no Internet Gateway, no NAT.
Reachability for Session Manager and logging is provided by VPC endpoints only, so
the box has no public IP and no inbound exposure. The instance security group's
egress is tight: 443 to the VPC (for the interface endpoints) and 443 to the git
host CIDR. Anthropic is reached only via the on-box proxy, which egresses 443.
"""

from __future__ import annotations

from aws_cdk import Environment, Stack
from aws_cdk import aws_ec2 as ec2
from cdk_nag import NagSuppressions
from constructs import Construct


class NetworkStack(Stack):
    vpc: ec2.Vpc
    instance_sg: ec2.SecurityGroup

    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        git_cidr: str = "",
        env: Environment | None = None,
    ) -> None:
        super().__init__(scope, construct_id, env=env)

        # Fail closed: a wildcard egress would defeat the boundary. An explicit
        # 0.0.0.0/0 is rejected; an empty git_cidr simply yields no git egress rule
        # (set -c git_cidr=<host/CIDR> to enable it on deploy).
        if git_cidr == "0.0.0.0/0":
            raise ValueError(
                "git_cidr must be a specific host CIDR, not 0.0.0.0/0 "
                "(egress fails closed for the agent boundary)"
            )

        self.vpc = ec2.Vpc(
            self,
            "Vpc",
            max_azs=1,
            nat_gateways=0,
            subnet_configuration=[
                ec2.SubnetConfiguration(
                    name="isolated",
                    subnet_type=ec2.SubnetType.PRIVATE_ISOLATED,
                    cidr_mask=24,
                )
            ],
        )
        # Flow logs to CloudWatch for auditability of the isolated subnet.
        self.vpc.add_flow_log("FlowLog")

        # Interface endpoints so SSM Session Manager + logging work with no inbound,
        # no NAT, no public IP.
        for name, svc in {
            "Ssm": ec2.InterfaceVpcEndpointAwsService.SSM,
            "SsmMessages": ec2.InterfaceVpcEndpointAwsService.SSM_MESSAGES,
            "Ec2Messages": ec2.InterfaceVpcEndpointAwsService.EC2_MESSAGES,
            "Logs": ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS,
        }.items():
            self.vpc.add_interface_endpoint(name, service=svc, private_dns_enabled=True)
        # S3 via a (free) gateway endpoint.
        self.vpc.add_gateway_endpoint("S3", service=ec2.GatewayVpcEndpointAwsService.S3)

        # The instance SG: no inbound; egress only to the VPC (endpoints) + the git host.
        self.instance_sg = ec2.SecurityGroup(
            self,
            "InstanceSg",
            vpc=self.vpc,
            description="agent host: 443 to VPC endpoints + the git host only",
            allow_all_outbound=False,
        )
        self.instance_sg.add_egress_rule(
            ec2.Peer.ipv4(self.vpc.vpc_cidr_block),
            ec2.Port.tcp(443),
            "443 to in-VPC interface endpoints (SSM, logs)",
        )
        if git_cidr:
            self.instance_sg.add_egress_rule(
                ec2.Peer.ipv4(git_cidr),
                ec2.Port.tcp(443),
                "443 to the git host (and Anthropic, reached via the on-box proxy)",
            )

        NagSuppressions.add_resource_suppressions(
            self.instance_sg,
            [
                {
                    "id": "AwsSolutions-EC23",
                    "reason": "Egress only; no inbound rules. 443 to the VPC CIDR targets "
                    "private interface endpoints, not the Internet.",
                }
            ],
            apply_to_children=True,
        )
