# Security group for the fleet instances (R10, house pattern).
#
# SSH (22) is admitted from two sources, never the world:
#   - the regional EC2 Instance Connect service ranges (browser-console EIC
#     originates from these) — there is no AWS-managed prefix list for EIC,
#     so the published ip-ranges.json is the source of truth;
#   - optional admin_cidr_blocks, because CLI-initiated
#     `aws ec2-instance-connect ssh` connects from the admin's own IP.
#
# Divergence from the runtime stack: no Lustre rules — the fleet has no FSx;
# its data moves through S3.
#
# NOTE: the EIC service ranges drift over time, which surfaces as occasional
# benign plan diffs on the ssh_eic rules. Expected; just apply them.
data "aws_ip_ranges" "ec2_instance_connect" {
  regions  = [var.region]
  services = ["ec2_instance_connect"]
}

resource "aws_security_group" "fleet" {
  name_prefix = "${local.name_prefix}-"
  description = "Fleet GPU instances: SSH via EC2 Instance Connect + admin CIDRs"
  vpc_id      = aws_vpc.this.id

  tags = merge(local.tags, { Name = local.name_prefix })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh_eic" {
  for_each = toset(data.aws_ip_ranges.ec2_instance_connect.cidr_blocks)

  security_group_id = aws_security_group.fleet.id
  description       = "SSH from EC2 Instance Connect service range (${var.region})"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"

  tags = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "ssh_admin" {
  for_each = toset(var.admin_cidr_blocks)

  security_group_id = aws_security_group.fleet.id
  description       = "SSH from admin CIDR"
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"

  tags = local.tags
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.fleet.id
  description       = "Allow all egress"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = local.tags
}
