# No inbound rules at all: the GitHub runners only make outbound connections,
# and shells go through SSM Session Manager (iam.tf), which is also outbound
# from the instance. The automation runs untrusted model code, so nothing on
# the internet should be able to reach this machine.

resource "aws_security_group" "host" {
  name_prefix = "${local.name_prefix}-"
  description = "Model-addition runners: no inbound; HTTPS and HTTP out"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { Name = local.name_prefix })

  lifecycle {
    create_before_destroy = true
  }
}

# Egress: HTTPS and HTTP only, to any address. The destinations (GitHub and its
# release downloads, Slack, the Anthropic API, SSM, Docker Hub, PyPI, npm, the
# Ubuntu and Docker apt mirrors) sit behind changing CDN ranges, so they can't be
# listed as CIDRs. DNS to the VPC resolver and NTP to the link-local time
# service are not filtered by security groups. The agent containers are held to
# a narrower list by the egress proxy (comparison repo, RUNBOOK section 3).
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.host.id
  description       = "HTTPS out"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"

  tags = local.tags
}

#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "http" {
  security_group_id = aws_security_group.host.id
  description       = "HTTP out (apt mirrors)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"

  tags = local.tags
}
