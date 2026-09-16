# Fleet stack tests — plan-only against a fully mocked AWS provider.
# No run here ever touches a real AWS account.

mock_provider "aws" {
  override_data {
    target = data.aws_ip_ranges.ec2_instance_connect
    values = {
      cidr_blocks = ["18.206.107.24/29"]
    }
  }
}

variables {
  region     = "us-east-1"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPublicKeyForTests test@example"
}

# 1. Default subnet_azs (["a", "b"]) → one public subnet per listed AZ, each
#    auto-assigning public IPs, each associated to the public route table
#    (R2, KTD9).
run "default_subnet_per_az" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2
    error_message = "The default subnet_azs must plan exactly one public subnet per listed AZ (two)."
  }

  assert {
    condition     = aws_subnet.public[0].availability_zone == "us-east-1a" && aws_subnet.public[1].availability_zone == "us-east-1b"
    error_message = "Subnet AZs must be region + suffix, in subnet_azs order."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch])
    error_message = "Every fleet subnet must auto-assign public IPs (map_public_ip_on_launch = true)."
  }

  assert {
    condition     = length(aws_subnet.public[*].cidr_block) == length(distinct(aws_subnet.public[*].cidr_block))
    error_message = "Per-AZ subnets must carve distinct CIDRs out of the VPC."
  }

  assert {
    condition     = length(aws_route_table_association.public) == 2
    error_message = "Every per-AZ subnet must be associated to the public route table."
  }
}

# 2. Operator steers AZ placement: three suffixes → three subnets (R2).
run "custom_subnet_azs_three" {
  command = plan

  variables {
    subnet_azs = ["a", "c", "f"]
  }

  assert {
    condition     = length(aws_subnet.public) == 3
    error_message = "Three subnet_azs entries must plan three subnets."
  }

  assert {
    condition     = aws_subnet.public[2].availability_zone == "us-east-1f"
    error_message = "Subnet AZs must follow the operator-supplied suffix list."
  }
}

# 3. Empty subnet_azs → validation failure (an empty list would otherwise
#    surface later as an opaque element()-on-empty-list crash in the
#    instance unit).
run "empty_subnet_azs_rejected" {
  command = plan

  variables {
    subnet_azs = []
  }

  expect_failures = [var.subnet_azs]
}

# 4. World-open SSH is rejected at the variable boundary (no 0.0.0.0/0 ever).
run "world_open_admin_cidr_rejected" {
  command = plan

  variables {
    admin_cidr_blocks = ["0.0.0.0/0"]
  }

  expect_failures = [var.admin_cidr_blocks]
}

# 5. IPv6 CIDRs are rejected at the variable boundary: the SSH rules are
#    IPv4-only (cidr_ipv4), so an IPv6 entry that passed validation would
#    only fail later, at apply.
run "ipv6_admin_cidr_rejected" {
  command = plan

  variables {
    admin_cidr_blocks = ["2001:db8::/32"]
  }

  expect_failures = [var.admin_cidr_blocks]
}

# 6. Default admin_cidr_blocks ([]) → no admin rules; port 22 ingress carries
#    only the (mocked) EIC service ranges (R10).
run "default_admin_cidrs_absent_from_sg" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.ssh_admin) == 0
    error_message = "No admin SSH rules may be planned when admin_cidr_blocks is empty."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.ssh_eic) == 1
    error_message = "Port 22 ingress must carry exactly the EIC service ranges (one mocked range)."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.ssh_eic["18.206.107.24/29"].cidr_ipv4 == "18.206.107.24/29"
    error_message = "EIC SSH rule must be sourced from the EIC service range."
  }
}

# 7. A valid admin CIDR plans exactly one port-22 admin rule alongside the
#    EIC ranges, and egress stays allow-all (R10 happy path).
run "admin_cidr_plans_ssh_rule" {
  command = plan

  variables {
    admin_cidr_blocks = ["203.0.113.7/32"]
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.ssh_admin) == 1
    error_message = "Exactly one admin SSH rule must be planned per admin CIDR."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.ssh_admin["203.0.113.7/32"].from_port == 22 && aws_vpc_security_group_ingress_rule.ssh_admin["203.0.113.7/32"].to_port == 22
    error_message = "Admin rules must cover exactly TCP 22."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.all.cidr_ipv4 == "0.0.0.0/0" && aws_vpc_security_group_egress_rule.all.ip_protocol == "-1"
    error_message = "Egress must stay allow-all (the containers pull images and reach S3)."
  }
}

# 8. Existing key pair short-circuits creation (R10).
run "existing_key_pair_skips_creation" {
  command = plan

  variables {
    existing_key_pair_name = "ops-existing"
    public_key             = null
  }

  assert {
    condition     = length(aws_key_pair.this) == 0
    error_message = "No aws_key_pair may be planned when existing_key_pair_name is set."
  }
}

# 9. A supplied public key registers exactly one key pair under the
#    fleet-specific name prefix (R10, KTD10 naming isolation).
run "public_key_creates_one_key_pair" {
  command = plan

  assert {
    condition     = length(aws_key_pair.this) == 1
    error_message = "Exactly one aws_key_pair must be planned when public_key is set."
  }

  assert {
    condition     = aws_key_pair.this[0].key_name_prefix == "multi-scale-fleet-"
    error_message = "The registered key pair must use the fleet-specific name prefix (KTD10)."
  }
}

# 10. Neither key variable set → validation failure naming both options.
run "neither_key_variable_fails_validation" {
  command = plan

  variables {
    existing_key_pair_name = null
    public_key             = null
  }

  expect_failures = [var.public_key]
}

# 11. Both key variables set → validation failure.
run "both_key_variables_fail_validation" {
  command = plan

  variables {
    existing_key_pair_name = "ops-existing"
    public_key             = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPublicKeyForTests test@example"
  }

  expect_failures = [var.public_key]
}
