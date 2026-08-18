# Runtime stack tests — plan-only against a fully mocked AWS provider.
# No run here ever touches a real AWS account.

mock_provider "aws" {
  # Baseline reservation: active, with exactly the default instance_count
  # available, so runs that don't care about capacity neither trip the launch
  # preconditions nor the under-subscription check. Runs that do care carry
  # their own run-level override_data.
  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone        = "us-east-1b"
      state                    = "active"
      available_instance_count = 1
      instance_type            = "p5.48xlarge"
    }
  }

  override_data {
    target = data.aws_ip_ranges.ec2_instance_connect
    values = {
      cidr_blocks = ["18.206.107.24/29"]
    }
  }

  override_data {
    target = data.aws_ssm_parameter.dlami
    values = {
      value = "ami-0123456789abcdef0"
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

# 9. Active reservation + defaults → exactly one instance, capacity-block
#    market type, targeted at the reservation, on the default AL2 DLAMI path
#    (R3, R4, AE3).
run "active_block_launches_one_instance" {
  command = plan

  assert {
    condition     = length(aws_instance.gpu) == 1
    error_message = "Exactly one instance must be planned by default (launch_instance = true, instance_count = 1)."
  }

  assert {
    condition     = aws_instance.gpu[0].instance_market_options[0].market_type == "capacity-block"
    error_message = "Instances must use the capacity-block market type."
  }

  assert {
    condition     = aws_instance.gpu[0].capacity_reservation_specification[0].capacity_reservation_target[0].capacity_reservation_id == "cr-0123456789abcdef0"
    error_message = "Instances must target the supplied capacity reservation ID."
  }

  assert {
    condition     = data.aws_ssm_parameter.dlami[0].name == "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-amazon-linux-2/latest/ami-id"
    error_message = "The default ami_flavor must resolve the AL2 DLAMI SSM path."
  }
}

# 10. Scheduled (not yet active) block + launch_instance = true → the launch
#     precondition fails with the legible wait-or-preprovision message (AE5,
#     KTD9 red-proof).
run "scheduled_block_fails_precondition" {
  command = plan

  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone        = "us-east-1b"
      state                    = "scheduled"
      available_instance_count = 1
      instance_type            = "p5.48xlarge"
    }
  }

  expect_failures = [
    aws_instance.gpu,
  ]
}

# 11. launch_instance = false → zero instances, and the plan succeeds even
#     against a still-scheduled block: the pre-provisioning path (AE5, KTD9).
run "pre_provisioning_before_block_start" {
  command = plan

  variables {
    launch_instance = false
  }

  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone        = "us-east-1b"
      state                    = "scheduled"
      available_instance_count = 1
      instance_type            = "p5.48xlarge"
    }
  }

  assert {
    condition     = length(aws_instance.gpu) == 0
    error_message = "No instance may be planned while launch_instance = false."
  }
}

# 12. instance_count above the reservation's available capacity → the
#     capacity precondition fails (KTD9).
run "over_subscription_fails_precondition" {
  command = plan

  variables {
    instance_count = 3
  }

  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone        = "us-east-1b"
      state                    = "active"
      available_instance_count = 2
      instance_type            = "p5.48xlarge"
    }
  }

  expect_failures = [
    aws_instance.gpu,
  ]
}

# 13. instance_count below available capacity → the under-subscription check
#     warns about the already-paid-for idle capacity (R10). The test framework
#     surfaces the check warning as an expected failure.
run "under_subscription_warns" {
  command = plan

  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone        = "us-east-1b"
      state                    = "active"
      available_instance_count = 2
      instance_type            = "p5.48xlarge"
    }
  }

  expect_failures = [
    check.capacity_block_under_subscribed,
  ]

  assert {
    condition     = length(aws_instance.gpu) == 1
    error_message = "Under-subscription must warn, not block: the single instance must still be planned."
  }
}

# 14. ami_flavor = "al2023" resolves the AL2023 DLAMI SSM path (R4, KTD3).
run "al2023_flavor_resolves_al2023_path" {
  command = plan

  variables {
    ami_flavor = "al2023"
  }

  assert {
    condition     = strcontains(data.aws_ssm_parameter.dlami[0].name, "amazon-linux-2023")
    error_message = "ami_flavor = \"al2023\" must resolve the AL2023 DLAMI SSM path."
  }
}

# 15. Explicit ami_id bypasses SSM entirely (KTD3): zero SSM lookups, and the
#     instance runs exactly the pinned AMI.
run "explicit_ami_id_bypasses_ssm" {
  command = plan

  variables {
    ami_id = "ami-0fedcba9876543210"
  }

  assert {
    condition     = length(data.aws_ssm_parameter.dlami) == 0
    error_message = "No SSM parameter lookup may be planned when ami_id is set."
  }

  assert {
    condition     = aws_instance.gpu[0].ami == "ami-0fedcba9876543210"
    error_message = "The instance must run the explicitly pinned AMI."
  }
}

# 16. instance_count = 2 within available capacity → two instances sharing
#     subnet, SG, and key pair.
run "multi_instance_launch" {
  command = plan

  variables {
    instance_count = 2
  }

  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone        = "us-east-1b"
      state                    = "active"
      available_instance_count = 2
      instance_type            = "p5.48xlarge"
    }
  }

  assert {
    condition     = length(aws_instance.gpu) == 2
    error_message = "Exactly two instances must be planned when instance_count = 2."
  }

  assert {
    condition     = aws_instance.gpu[0].instance_market_options[0].market_type == "capacity-block" && aws_instance.gpu[1].instance_market_options[0].market_type == "capacity-block"
    error_message = "Every instance must use the capacity-block market type."
  }
}

# 17. Hardening: IMDSv2 is mandatory and the root volume is an encrypted gp3
#     that dies with the instance (security amendments to U4).
run "imdsv2_and_encrypted_root_volume" {
  command = plan

  assert {
    condition     = aws_instance.gpu[0].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be mandatory (http_tokens = \"required\")."
  }

  assert {
    condition     = aws_instance.gpu[0].metadata_options[0].http_endpoint == "enabled" && aws_instance.gpu[0].metadata_options[0].http_put_response_hop_limit == 2
    error_message = "IMDS must stay enabled with hop limit 2 for containerized workloads."
  }

  assert {
    condition     = aws_instance.gpu[0].root_block_device[0].encrypted == true && aws_instance.gpu[0].root_block_device[0].delete_on_termination == true
    error_message = "The root volume must be encrypted and delete on termination."
  }

  assert {
    condition     = aws_instance.gpu[0].root_block_device[0].volume_type == "gp3" && aws_instance.gpu[0].root_block_device[0].volume_size == 100
    error_message = "The root volume must be a gp3 of the default 100 GiB."
  }
}
