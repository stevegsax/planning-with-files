"""EgressStack — the box's ONLY path to the internet: a domain-allowlist forward proxy.

The agent host sits in a PRIVATE_ISOLATED subnet (no NAT, no IGW). Anthropic's API is
a CDN whose IPs cannot be pinned in a security group, so the egress is a *forward
proxy* the on-box brokering proxy CONNECT-tunnels through — not a routing NAT (a
default 0.0.0.0/0 route would force the agent-host SG to allow 0.0.0.0/0:443, breaking
the M6 fail-closed boundary).

This stack attaches the egress capability to the EXISTING VPC as raw L1 constructs so
the long-lived NetworkStack keeps its IGW/NAT count at zero (its isolation claim stays
literally true): an Internet Gateway, a tiny /28 PUBLIC subnet, a public route table,
and a t4g.nano Squid instance. The agent host reaches Squid over the VPC's implicit
intra-VPC local route — no NAT gateway, no route-table edit on the isolated subnet.

Squid enforces a CONNECT allowlist (api.anthropic.com only); TLS is end-to-end to
Anthropic, so a compromised Squid never sees the brokered key. The single egress path
the agent host gains — tcp/3128 to the Squid SG — is wired as STANDALONE L1 SG rules
here (group_id = the imported instance SG) so it renders as DestinationSecurityGroupId,
never a CIDR, and never lands as an inline rule on the agent-host SG (M6 stays green).

The fenced agent uid cannot reach Squid at all (the on-box egress-lock owner-match
drops every non-loopback packet from the agent); only the proxy/gov/root uids egress.
"""

from __future__ import annotations

from pathlib import Path

from aws_cdk import CfnOutput, Environment, Stack
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_iam as iam
from cdk_nag import NagSuppressions
from constructs import Construct


class EgressStack(Stack):
    squid: ec2.Instance

    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        vpc: ec2.IVpc,
        instance_sg: ec2.ISecurityGroup,
        squid_cloud_init_path: Path,
        public_cidr: str = "10.0.250.0/28",
        env: Environment | None = None,
    ) -> None:
        super().__init__(scope, construct_id, env=env)

        # Same AZ as the (single) isolated subnet; intra-VPC routing would work
        # cross-AZ too, but co-locating avoids needless cross-AZ data charges.
        az = vpc.availability_zones[0]

        # --- Internet egress for the proxy box ONLY: IGW + a /28 public subnet ---
        # Raw L1 so PwfgNetwork (which owns the VPC) keeps InternetGateway count 0.
        igw = ec2.CfnInternetGateway(self, "Igw")
        igw_attach = ec2.CfnVPCGatewayAttachment(
            self, "IgwAttach", vpc_id=vpc.vpc_id, internet_gateway_id=igw.ref
        )
        public_subnet = ec2.CfnSubnet(
            self,
            "PublicSubnet",
            vpc_id=vpc.vpc_id,
            cidr_block=public_cidr,
            availability_zone=az,
            map_public_ip_on_launch=True,
        )
        public_rt = ec2.CfnRouteTable(self, "PublicRt", vpc_id=vpc.vpc_id)
        default_route = ec2.CfnRoute(
            self,
            "DefaultRoute",
            route_table_id=public_rt.ref,
            destination_cidr_block="0.0.0.0/0",
            gateway_id=igw.ref,
        )
        default_route.add_dependency(igw_attach)
        route_assoc = ec2.CfnSubnetRouteTableAssociation(
            self,
            "PublicRtAssoc",
            subnet_id=public_subnet.ref,
            route_table_id=public_rt.ref,
        )
        imported_public = ec2.Subnet.from_subnet_attributes(
            self,
            "ImportedPublic",
            subnet_id=public_subnet.ref,
            availability_zone=az,
            route_table_id=public_rt.ref,
        )

        # --- the Squid SG: accepts 3128 from the agent host only; egresses 443 (the
        # CONNECT tunnel) + 53 (resolve the CONNECT host). The 0.0.0.0/0:443 here is
        # the controlled chokepoint, not the "agent host" SG, so M6's description
        # filter never sees it.
        squid_sg = ec2.SecurityGroup(
            self,
            "SquidSg",
            vpc=vpc,
            description="egress forward proxy (squid): 3128 from agent host; 443+53 out",
            allow_all_outbound=False,
        )
        squid_sg.add_egress_rule(
            ec2.Peer.any_ipv4(), ec2.Port.tcp(443), "443 CONNECT tunnel to the allowlisted upstream"
        )
        # DNS to resolve the CONNECT host — scoped to the VPC resolver (the SG is
        # allow_all_outbound=False, so this rule is load-bearing), NOT 0.0.0.0/0, so a
        # compromised Squid has no public-DNS exfil channel. Cover both the VPC+2
        # resolver (in the VPC CIDR) and the link-local Amazon resolver.
        for dns_dest, where in (
            (ec2.Peer.ipv4(vpc.vpc_cidr_block), "the VPC+2 resolver"),
            (ec2.Peer.ipv4("169.254.169.253/32"), "the link-local Amazon resolver"),
        ):
            squid_sg.add_egress_rule(dns_dest, ec2.Port.tcp(53), f"DNS (tcp) to {where}")
            squid_sg.add_egress_rule(dns_dest, ec2.Port.udp(53), f"DNS (udp) to {where}")

        # Break the SG<->SG reference cycle with STANDALONE L1 rules. The agent-host
        # egress rule lives HERE (group_id = the imported instance SG) so it renders as
        # DestinationSecurityGroupId on a separate resource — never an inline CIDR rule
        # on the agent-host SG (the M6 invariant).
        ec2.CfnSecurityGroupIngress(
            self,
            "SquidFromAgent3128",
            group_id=squid_sg.security_group_id,
            ip_protocol="tcp",
            from_port=3128,
            to_port=3128,
            source_security_group_id=instance_sg.security_group_id,
            description="agent host -> squid forward proxy",
        )
        ec2.CfnSecurityGroupEgress(
            self,
            "AgentToSquid3128",
            group_id=instance_sg.security_group_id,
            ip_protocol="tcp",
            from_port=3128,
            to_port=3128,
            destination_security_group_id=squid_sg.security_group_id,
            description="agent host egress to the squid forward proxy (3128) only",
        )

        # --- the Squid box: least-priv (SSM-core ONLY; no agent role, no SecureString
        # / KMS access), IMDSv2 (hop limit forced by the app-wide aspect), encrypted
        # root, no inbound except 3128 from the agent host.
        squid_role = iam.Role(
            self,
            "EgressRole",
            assumed_by=iam.ServicePrincipal("ec2.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name("AmazonSSMManagedInstanceCore")
            ],
        )
        self.squid = ec2.Instance(
            self,
            "Squid",
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(subnets=[imported_public]),
            instance_type=ec2.InstanceType.of(ec2.InstanceClass.T4G, ec2.InstanceSize.NANO),
            machine_image=ec2.MachineImage.latest_amazon_linux2023(
                cpu_type=ec2.AmazonLinuxCpuType.ARM_64
            ),
            security_group=squid_sg,
            role=squid_role,
            require_imdsv2=True,
            detailed_monitoring=True,
            user_data=ec2.UserData.custom(squid_cloud_init_path.read_text()),
            block_devices=[
                ec2.BlockDevice(
                    device_name="/dev/xvda",
                    volume=ec2.BlockDeviceVolume.ebs(
                        8,
                        volume_type=ec2.EbsDeviceVolumeType.GP3,
                        encrypted=True,
                        delete_on_termination=True,
                    ),
                )
            ],
        )
        # The box must not boot (and run cloud-init's `dnf install squid`, which needs
        # the internet) until its egress route is actually live: depend on the default
        # route + the subnet association, not just the IGW attachment. CloudFormation
        # cannot infer this (the route is a separate resource the instance only Refs the
        # subnet of), and a missed race permanently wedges Squid bootstrap.
        self.squid.node.add_dependency(igw_attach)
        self.squid.node.add_dependency(default_route)
        self.squid.node.add_dependency(route_assoc)

        CfnOutput(
            self,
            "SquidPrivateIp",
            value=self.squid.instance_private_ip,
            description="Squid private IP; set PWFG_PROXY_FORWARD=http://<ip>:3128 out of band.",
        )

        NagSuppressions.add_resource_suppressions(
            squid_role,
            [
                {
                    "id": "AwsSolutions-IAM4",
                    "reason": "AmazonSSMManagedInstanceCore is the AWS-recommended policy for "
                    "Session Manager (to inspect Squid); the egress box has no other privilege.",
                }
            ],
            apply_to_children=True,
        )
        NagSuppressions.add_resource_suppressions(
            self.squid,
            [
                {
                    "id": "AwsSolutions-EC28",
                    "reason": "Detailed monitoring is enabled; ASG/auto-recovery is out of scope "
                    "for a disposable single egress box (teardown is P2).",
                },
                {
                    "id": "AwsSolutions-EC29",
                    "reason": "Disposable single egress box; termination protection would fight "
                    "the intended teardown lifecycle.",
                },
            ],
            apply_to_children=True,
        )
