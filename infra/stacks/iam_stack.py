"""IamStack — the instance role, least-privileged to the secrets it must fetch.

The role can do exactly four things: be managed by SSM (the AWS-recommended core
policy, for Session Manager), read the two named SecureString parameters, decrypt
them with one customer-managed CMK *only via SSM*, and write to one audit log group.
No GetParametersByPath, no kms:*, no S3/EC2/IAM. The brokered key is never broader
than this, and the on-box IMDS lock keeps even this role away from the agent uid.
"""

from __future__ import annotations

from aws_cdk import Environment, Stack
from aws_cdk import aws_iam as iam
from cdk_nag import NagSuppressions
from constructs import Construct


class IamStack(Stack):
    role: iam.Role

    def __init__(
        self,
        scope: Construct,
        construct_id: str,
        *,
        key_param_arn: str,
        deploy_key_param_arn: str,
        cmk_arn: str,
        audit_log_group_arn: str,
        env: Environment | None = None,
    ) -> None:
        super().__init__(scope, construct_id, env=env)

        self.role = iam.Role(
            self,
            "AgentHostRole",
            assumed_by=iam.ServicePrincipal("ec2.amazonaws.com"),
            managed_policies=[
                iam.ManagedPolicy.from_aws_managed_policy_name("AmazonSSMManagedInstanceCore")
            ],
        )

        # Exactly the two SecureString parameters — no path wildcard.
        self.role.add_to_policy(
            iam.PolicyStatement(
                sid="ReadTheTwoSecureStrings",
                actions=["ssm:GetParameter", "ssm:GetParameters"],
                resources=[key_param_arn, deploy_key_param_arn],
            )
        )
        # Decrypt those parameters with one CMK, and only when SSM is the caller.
        self.role.add_to_policy(
            iam.PolicyStatement(
                sid="DecryptViaSsmOnly",
                actions=["kms:Decrypt"],
                resources=[cmk_arn],
                conditions={
                    "StringEquals": {
                        "kms:ViaService": f"ssm.{self.region}.amazonaws.com"
                    }
                },
            )
        )
        # Append-only audit logging to one log group's streams.
        self.role.add_to_policy(
            iam.PolicyStatement(
                sid="AuditLogPut",
                actions=["logs:PutLogEvents", "logs:CreateLogStream"],
                resources=[audit_log_group_arn, audit_log_group_arn + ":*"],
            )
        )

        NagSuppressions.add_resource_suppressions(
            self.role,
            [
                {
                    "id": "AwsSolutions-IAM4",
                    "reason": "AmazonSSMManagedInstanceCore is the AWS-recommended policy "
                    "for Session Manager; replacing it by hand would be less safe.",
                },
                {
                    "id": "AwsSolutions-IAM5",
                    "reason": "The only wildcard is on the single audit log group's stream "
                    "ARN suffix (':*'); PutLogEvents requires per-stream resources within "
                    "one named group. No service-level wildcards.",
                },
            ],
            apply_to_children=True,
        )
