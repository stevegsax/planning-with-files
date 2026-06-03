"""Offline synth + cdk-nag assertions for the Phase-1 stacks.

No AWS account needed: builds the app with placeholder context, synthesizes, and
asserts the security-load-bearing properties hold and that cdk-nag (AwsSolutions)
reports no un-suppressed errors. Run from infra/:
  uv run --python 3.13 --with aws-cdk-lib --with constructs --with cdk-nag \
    --with pytest python -m pytest tests/test_synth.py -q
"""

from __future__ import annotations

import pytest
from aws_cdk import App
from aws_cdk.assertions import Annotations, Match, Template

from app import build

STACKS = ["PwfgNetwork", "PwfgIam", "PwfgAgentHost", "PwfgEgress"]


@pytest.fixture(scope="module")
def app() -> App:
    a = App()
    build(a)
    return a


def _template(app: App, stack_id: str) -> Template:
    return Template.from_stack(app.node.find_child(stack_id))


def test_no_nag_errors(app: App) -> None:
    for stack_id in STACKS:
        stack = app.node.find_child(stack_id)
        errors = Annotations.from_stack(stack).find_error(
            "*", Match.string_like_regexp(r"AwsSolutions-.*")
        )
        msgs = [e.entry.data for e in errors]
        assert not msgs, f"{stack_id} has un-suppressed nag errors: {msgs}"


def test_imdsv2_required_with_hop_limit_1(app: App) -> None:
    tpl = _template(app, "PwfgAgentHost")
    tpl.has_resource_properties(
        "AWS::EC2::LaunchTemplate",
        {
            "LaunchTemplateData": Match.object_like(
                {
                    "MetadataOptions": {
                        "HttpTokens": "required",
                        "HttpPutResponseHopLimit": 1,
                    }
                }
            )
        },
    )


def test_root_volume_is_encrypted(app: App) -> None:
    tpl = _template(app, "PwfgAgentHost")
    encrypted_ebs = Match.object_like({"Ebs": Match.object_like({"Encrypted": True})})
    tpl.has_resource_properties(
        "AWS::EC2::Instance",
        {"BlockDeviceMappings": Match.array_with([encrypted_ebs])},
    )


def test_no_inbound_security_group_rules(app: App) -> None:
    tpl = _template(app, "PwfgNetwork")
    # The INSTANCE SG (not the per-endpoint SGs, which legitimately accept 443) must
    # have no ingress rules at all.
    instance_sgs = [
        res
        for res in tpl.find_resources("AWS::EC2::SecurityGroup").values()
        if "agent host" in str(res.get("Properties", {}).get("GroupDescription", ""))
    ]
    assert instance_sgs, "instance SG not found by description"
    for res in instance_sgs:
        ingress = res["Properties"].get("SecurityGroupIngress")
        assert not ingress, "instance SG must have no inbound rules"


def test_iam_has_no_service_wildcards(app: App) -> None:
    tpl = _template(app, "PwfgIam")
    for _, res in tpl.find_resources("AWS::IAM::Policy").items():
        for stmt in res["Properties"]["PolicyDocument"]["Statement"]:
            actions = stmt["Action"] if isinstance(stmt["Action"], list) else [stmt["Action"]]
            for action in actions:
                assert action != "*", "no full wildcard actions"
                assert not action.endswith(":*"), f"no service-level wildcard: {action}"


def test_vpc_is_isolated_no_nat_or_igw(app: App) -> None:
    tpl = _template(app, "PwfgNetwork")
    tpl.resource_count_is("AWS::EC2::NatGateway", 0)
    tpl.resource_count_is("AWS::EC2::InternetGateway", 0)


def test_egress_fails_closed_no_wildcard(app: App) -> None:
    # With no -c git_cidr (the offline/test path), the INSTANCE SG must NOT egress to
    # 0.0.0.0/0 — egress fails closed rather than opening to the whole Internet. (The
    # per-endpoint SGs legitimately allow-all outbound; scope to the instance SG by
    # its description, as test_no_inbound_security_group_rules does.)
    tpl = _template(app, "PwfgNetwork")
    instance_sgs = [
        res
        for res in tpl.find_resources("AWS::EC2::SecurityGroup").values()
        if "agent host" in str(res.get("Properties", {}).get("GroupDescription", ""))
    ]
    assert instance_sgs, "instance SG not found by description"
    for res in instance_sgs:
        for rule in res["Properties"].get("SecurityGroupEgress", []) or []:
            assert rule.get("CidrIp") != "0.0.0.0/0", f"wildcard egress on the instance SG: {rule}"
            # Harden: IPv6 must not be a wildcard back door either.
            assert rule.get("CidrIpv6") != "::/0", (
                f"wildcard IPv6 egress on the instance SG: {rule}"
            )


def test_agent_sg_egress_to_squid_is_sg_referenced_not_cidr(app: App) -> None:
    # The box's only added egress (3128 -> the Squid SG) must be a STANDALONE,
    # SG-referenced rule in PwfgEgress: DestinationSecurityGroupId, no CIDR, port 3128.
    # This is both the M6-preserving shape AND a regression guard that the egress path
    # exists (a dropped path would strand the proxy).
    tpl = _template(app, "PwfgEgress")
    egress_rules = tpl.find_resources("AWS::EC2::SecurityGroupEgress")
    to_squid = [
        r
        for r in egress_rules.values()
        if r["Properties"].get("ToPort") == 3128
        and r["Properties"].get("DestinationSecurityGroupId") is not None
    ]
    assert to_squid, "no standalone SG-referenced agent->squid:3128 egress rule found"
    for r in to_squid:
        assert "CidrIp" not in r["Properties"], "agent->squid egress must not be a CIDR rule"
        assert r["Properties"].get("IpProtocol") == "tcp"


def test_internet_egress_is_on_the_squid_sg_not_the_agent_host(app: App) -> None:
    # The agent-host SG must have NO internet (0.0.0.0/0) egress (M6, stated explicitly
    # cross-stack); the intentional 443 internet egress belongs to the Squid forward
    # proxy. The CDK-managed interface-endpoint SGs allow-all-outbound by default —
    # accepted and out of scope here, as the other SG tests note.
    net = _template(app, "PwfgNetwork")
    for res in net.find_resources("AWS::EC2::SecurityGroup").values():
        desc = str(res.get("Properties", {}).get("GroupDescription", ""))
        if "agent host" not in desc:
            continue
        for rule in res["Properties"].get("SecurityGroupEgress", []) or []:
            assert rule.get("CidrIp") != "0.0.0.0/0", f"wildcard egress on agent-host SG: {rule}"
            assert rule.get("CidrIpv6") != "::/0"

    egr = _template(app, "PwfgEgress")
    squid_sgs = [
        res
        for res in egr.find_resources("AWS::EC2::SecurityGroup").values()
        if "egress forward proxy" in str(res.get("Properties", {}).get("GroupDescription", ""))
    ]
    assert len(squid_sgs) == 1, "expected exactly one squid forward-proxy SG"
    egress = squid_sgs[0]["Properties"].get("SecurityGroupEgress", []) or []
    assert any(
        r.get("CidrIp") == "0.0.0.0/0" and r.get("ToPort") == 443 for r in egress
    ), "squid SG must egress 443 to the internet (the CONNECT tunnel)"


def test_egress_box_is_least_privileged(app: App) -> None:
    # The Squid box must reach NO secrets: SSM-core managed policy only, and zero
    # inline IAM policies (so no SecureString / KMS / S3 grants exist on its role).
    tpl = _template(app, "PwfgEgress")
    tpl.resource_count_is("AWS::IAM::Policy", 0)
    roles = tpl.find_resources("AWS::IAM::Role")
    assert len(roles) == 1, f"expected exactly one egress-box role, got {len(roles)}"


def test_egress_path_lives_only_in_the_egress_stack(app: App) -> None:
    # The IGW/NAT belong to PwfgEgress; PwfgNetwork stays isolated (IGW=0, NAT=0) so
    # its isolation claim is literally true.
    egr = _template(app, "PwfgEgress")
    egr.resource_count_is("AWS::EC2::InternetGateway", 1)
    egr.resource_count_is("AWS::EC2::NatGateway", 0)
    net = _template(app, "PwfgNetwork")
    net.resource_count_is("AWS::EC2::InternetGateway", 0)
    net.resource_count_is("AWS::EC2::NatGateway", 0)


def test_explicit_wildcard_git_cidr_is_rejected() -> None:
    # Passing an explicit 0.0.0.0/0 must fail loudly (fail closed), not synthesize.
    from stacks.network_stack import NetworkStack

    with pytest.raises(ValueError, match="0.0.0.0/0"):
        NetworkStack(App(), "PwfgNetworkWildcard", git_cidr="0.0.0.0/0")
