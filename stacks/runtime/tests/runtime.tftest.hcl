# Runtime stack tests — plan-only against a fully mocked AWS provider.
# No run here ever touches a real AWS account.

mock_provider "aws" {
  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone = "us-east-1b"
      state             = "active"
    }
  }

  override_data {
    target = data.aws_ip_ranges.ec2_instance_connect
    values = {
      cidr_blocks = ["18.206.107.24/29"]
    }
  }
}

variables {
  region                  = "us-east-1"
  capacity_reservation_id = "cr-0123456789abcdef0"
  public_key              = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPublicKeyForTests test@example"
}

# 1. The subnet lands in the reservation's AZ (KTD4).
run "subnet_az_matches_reservation" {
  command = plan

  assert {
    condition     = aws_subnet.public.availability_zone == "us-east-1b"
    error_message = "Public subnet AZ must be derived from the capacity reservation's AZ."
  }
}

# 2. Existing key pair short-circuits creation (R5).
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

# 3. A supplied public key registers exactly one key pair (R5).
run "public_key_creates_one_key_pair" {
  command = plan

  assert {
    condition     = length(aws_key_pair.this) == 1
    error_message = "Exactly one aws_key_pair must be planned when public_key is set."
  }
}

# 4. Neither key variable set → validation failure naming both options.
run "neither_key_variable_fails_validation" {
  command = plan

  variables {
    existing_key_pair_name = null
    public_key             = null
  }

  expect_failures = [var.public_key]
}

# 5. Both key variables set → validation failure.
run "both_key_variables_fail_validation" {
  command = plan

  variables {
    existing_key_pair_name = "ops-existing"
    public_key             = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPublicKeyForTests test@example"
  }

  expect_failures = [var.public_key]
}

# 6. World-open SSH is rejected at the variable boundary (no 0.0.0.0/0 ever).
run "world_open_admin_cidr_rejected" {
  command = plan

  variables {
    admin_cidr_blocks = ["0.0.0.0/0"]
  }

  expect_failures = [var.admin_cidr_blocks]
}

# 7. Default admin_cidr_blocks ([]) → no admin rules; port 22 ingress carries
#    only the (mocked) EIC service ranges.
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

# 8. Lustre rules are self-referencing only — no CIDR source.
run "lustre_rules_self_referencing_only" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.lustre_988.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.lustre_988.cidr_ipv6 == null
    error_message = "Lustre port 988 rule must have no CIDR source (self-referencing only)."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.lustre_988.from_port == 988 && aws_vpc_security_group_ingress_rule.lustre_988.to_port == 988
    error_message = "Lustre LNet rule must cover exactly TCP 988."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.lustre_1018_1023.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.lustre_1018_1023.cidr_ipv6 == null
    error_message = "Lustre 1018-1023 rule must have no CIDR source (self-referencing only)."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.lustre_1018_1023.from_port == 1018 && aws_vpc_security_group_ingress_rule.lustre_1018_1023.to_port == 1023
    error_message = "Lustre auxiliary rule must cover exactly TCP 1018-1023."
  }
}
