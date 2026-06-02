"""App-wide aspects: cdk-nag's AwsSolutions checks + the IMDS hop-limit hardening."""

from __future__ import annotations

import jsii
from aws_cdk import Aspects, IAspect
from aws_cdk import aws_ec2 as ec2
from cdk_nag import AwsSolutionsChecks
from constructs import IConstruct


@jsii.implements(IAspect)
class ImdsHopLimitAspect:
    """Force IMDSv2 + a hop limit of 1 on every launch template in scope.

    ec2.Instance(require_imdsv2=True) creates a launch template and sets HttpTokens,
    but not the hop limit; a hop limit of 1 stops a container/pod on the box from
    reaching IMDS through the instance. Setting both on the rendered
    AWS::EC2::LaunchTemplate firms up the control-plane half of the IMDS defense.
    """

    def visit(self, node: IConstruct) -> None:
        if isinstance(node, ec2.CfnLaunchTemplate):
            node.add_property_override(
                "LaunchTemplateData.MetadataOptions",
                {"HttpTokens": "required", "HttpPutResponseHopLimit": 1, "HttpEndpoint": "enabled"},
            )


def apply_security_aspects(scope: IConstruct) -> None:
    Aspects.of(scope).add(ImdsHopLimitAspect())
    Aspects.of(scope).add(AwsSolutionsChecks(verbose=True))
