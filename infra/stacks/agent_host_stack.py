"""AgentHostStack — the replaceable instance, separate from the long-lived net/IAM.

A Graviton (t4g.small) AL2023 box on the isolated subnet with the least-priv role
and the egress SG, an encrypted gp3 root, IMDSv2 REQUIRED with a hop limit of 1, and
cloud-init user-data that lays out /srv/pwfg and starts the proxy + loop units. The
SecureString VALUES are created out of band and referenced by name — never put in
this template.
"""

from __future__ import annotations

from pathlib import Path

from aws_cdk import Environment, Stack
from aws_cdk import aws_ec2 as ec2
from aws_cdk import aws_iam as iam
from cdk_nag import NagSuppressions
from constructs import Construct


class AgentHostStack(Stack):
    instance: ec2.Instance

    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        vpc: ec2.IVpc,
        instance_sg: ec2.ISecurityGroup,
        role: iam.IRole,
        cloud_init_path: Path,
        env: Environment | None = None,
    ) -> None:
        super().__init__(scope, construct_id, env=env)

        user_data = ec2.UserData.custom(cloud_init_path.read_text())

        self.instance = ec2.Instance(
            self,
            "Agent",
            vpc=vpc,
            vpc_subnets=ec2.SubnetSelection(subnet_type=ec2.SubnetType.PRIVATE_ISOLATED),
            instance_type=ec2.InstanceType.of(
                ec2.InstanceClass.T4G, ec2.InstanceSize.SMALL
            ),
            machine_image=ec2.MachineImage.latest_amazon_linux2023(
                cpu_type=ec2.AmazonLinuxCpuType.ARM_64
            ),
            security_group=instance_sg,
            role=role,
            require_imdsv2=True,
            detailed_monitoring=True,
            user_data=user_data,
            block_devices=[
                ec2.BlockDevice(
                    device_name="/dev/xvda",
                    volume=ec2.BlockDeviceVolume.ebs(
                        20,
                        volume_type=ec2.EbsDeviceVolumeType.GP3,
                        encrypted=True,
                        delete_on_termination=True,
                    ),
                )
            ],
        )

        NagSuppressions.add_resource_suppressions(
            self.instance,
            [
                {
                    "id": "AwsSolutions-EC28",
                    "reason": "Detailed monitoring is enabled; auto-recovery/ASG is out of "
                    "scope for a disposable single-task box (teardown is P2).",
                },
                {
                    "id": "AwsSolutions-EC29",
                    "reason": "Disposable single-task instance; termination protection would "
                    "fight the intended teardown lifecycle.",
                },
            ],
            apply_to_children=True,
        )
