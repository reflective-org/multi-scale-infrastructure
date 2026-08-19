# Runtime stack tests — plan-only against a fully mocked AWS provider.
# No run here ever touches a real AWS account.

mock_provider "aws" {
  # Baseline reservation: active, with a total size (instance_count) exactly
  # matching the default var.instance_count, so runs that don't care about
  # capacity neither trip the launch preconditions nor the under-subscription
  # check. Runs that do care carry their own run-level override_data.
  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone = "us-east-1b"
      state             = "active"
      instance_count    = 1
      instance_type     = "p5.48xlarge"
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

  # The DRA's file_system_id is provider-validated to the fs- prefix at plan
  # time, so the auto-generated mock id would be rejected. Well-formed mocked
  # endpoints also keep the user_data seam assertable when FSx is enabled.
  override_resource {
    target = aws_fsx_lustre_file_system.data
    values = {
      id         = "fs-0123456789abcdef0"
      dns_name   = "fs-0123456789abcdef0.fsx.us-east-1.amazonaws.com"
      mount_name = "mockmnt"
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
      availability_zone = "us-east-1b"
      state             = "scheduled"
      instance_count    = 1
      instance_type     = "p5.48xlarge"
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
      availability_zone = "us-east-1b"
      state             = "scheduled"
      instance_count    = 1
      instance_type     = "p5.48xlarge"
    }
  }

  assert {
    condition     = length(aws_instance.gpu) == 0
    error_message = "No instance may be planned while launch_instance = false."
  }
}

# 12. instance_count above the block's total size → the capacity precondition
#     fails (KTD9). The comparison is against the block's TOTAL instance_count,
#     not available_instance_count — the remaining counter shrinks as our own
#     instances launch and would wedge every post-launch plan.
run "over_subscription_fails_precondition" {
  command = plan

  variables {
    instance_count = 3
  }

  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone = "us-east-1b"
      state             = "active"
      instance_count    = 2
      instance_type     = "p5.48xlarge"
    }
  }

  expect_failures = [
    aws_instance.gpu,
  ]
}

# 13. instance_count below the block's total size → the under-subscription
#     check warns about the already-paid-for idle capacity (R10). The test
#     framework surfaces the check warning as an expected failure.
run "under_subscription_warns" {
  command = plan

  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone = "us-east-1b"
      state             = "active"
      instance_count    = 2
      instance_type     = "p5.48xlarge"
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

# 16. instance_count = 2 exactly filling the block → two instances sharing
#     subnet, SG, and key pair.
run "multi_instance_launch" {
  command = plan

  variables {
    instance_count = 2
  }

  override_data {
    target = data.aws_ec2_capacity_block_reservation.this
    values = {
      availability_zone = "us-east-1b"
      state             = "active"
      instance_count    = 2
      instance_type     = "p5.48xlarge"
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

# NOTE on the enable_fsx flip against RUNNING instances: aws_instance.gpu
# carries lifecycle ignore_changes = [user_data] so that flipping enable_fsx
# never stop/starts or replaces an existing instance (cloud-init would not
# re-run anyway). Plan-only tests cannot model existing state, so that
# contract is apply-time behavior verified manually — no test here asserts it.

# 18. FSx disabled (the default) → zero FSx resources planned, and the
#     rendered user_data carries no Lustre content at all (R7, AE4). The
#     instance's user_data is assertable at plan time here because the
#     disabled seam is a known empty string — nothing unknown feeds the
#     template.
run "fsx_disabled_by_default" {
  command = plan

  assert {
    condition     = length(aws_fsx_lustre_file_system.data) == 0
    error_message = "No FSx file system may be planned while enable_fsx = false (the default)."
  }

  assert {
    condition     = length(aws_fsx_data_repository_association.s3) == 0
    error_message = "No FSx data repository association may be planned while enable_fsx = false (the default)."
  }

  assert {
    condition     = !strcontains(lower(aws_instance.gpu[0].user_data), "lustre")
    error_message = "The rendered user_data must contain no Lustre content while FSx is disabled."
  }
}

# 19. FSx enabled with a bucket → exactly one PERSISTENT_2 file system (at the
#     1200 GiB default, which must pass validation) and one DRA rooted at the
#     bucket (R7, KTD7, AE4). The instance's user_data is assertable here only
#     because the file-level override_resource pins dns_name/mount_name to
#     known values at plan; against real AWS they are computed.
run "fsx_enabled_plans_file_system_and_dra" {
  command = plan

  variables {
    enable_fsx    = true
    fsx_s3_bucket = "multi-scale-training-data"
  }

  assert {
    condition     = length(aws_fsx_lustre_file_system.data) == 1 && length(aws_fsx_data_repository_association.s3) == 1
    error_message = "Exactly one FSx file system and one DRA must be planned when enable_fsx = true."
  }

  assert {
    condition     = aws_fsx_lustre_file_system.data[0].deployment_type == "PERSISTENT_2"
    error_message = "The file system must be PERSISTENT_2 — the only deployment type supporting DRA auto-export (KTD7)."
  }

  assert {
    condition     = aws_fsx_lustre_file_system.data[0].storage_capacity == 1200 && aws_fsx_lustre_file_system.data[0].per_unit_storage_throughput == 250
    error_message = "The default capacity (1200 GiB) and throughput (250 MB/s/TiB) must plan cleanly."
  }

  assert {
    condition     = aws_fsx_data_repository_association.s3[0].data_repository_path == "s3://multi-scale-training-data"
    error_message = "The DRA must be rooted at s3://<fsx_s3_bucket>."
  }

  assert {
    condition     = aws_fsx_data_repository_association.s3[0].file_system_path == "/" && aws_fsx_data_repository_association.s3[0].batch_import_meta_data_on_create == true
    error_message = "The DRA must link the file system root and batch-import the bucket's metadata on create."
  }

  assert {
    condition     = tolist(aws_fsx_data_repository_association.s3[0].s3[0].auto_import_policy[0].events) == tolist(["NEW", "CHANGED", "DELETED"])
    error_message = "Auto-import must cover NEW, CHANGED, and DELETED events."
  }

  assert {
    condition     = length(aws_fsx_data_repository_association.s3[0].s3[0].auto_export_policy) == 1 && tolist(aws_fsx_data_repository_association.s3[0].s3[0].auto_export_policy[0].events) == tolist(["NEW", "CHANGED", "DELETED"])
    error_message = "Auto-export must default on, covering NEW, CHANGED, and DELETED events."
  }

  # End-to-end through the user_data seam: the rendered script must carry the
  # exact fstab entry — mocked endpoints, /data, and the mandatory _netdev.
  assert {
    condition     = strcontains(aws_instance.gpu[0].user_data, "fs-0123456789abcdef0.fsx.us-east-1.amazonaws.com@tcp:/mockmnt /data lustre defaults,relatime,flock,_netdev,x-systemd.automount 0 0")
    error_message = "The rendered user_data must append the fstab entry built from the file system's dns_name and mount_name, mounted at /data with _netdev."
  }
}

# 20. fsx_auto_export = false → import-only DRA: the s3 block carries an
#     auto_import_policy but no auto_export_policy (KTD7 read-only bucket
#     fork).
run "fsx_import_only_when_auto_export_disabled" {
  command = plan

  variables {
    enable_fsx      = true
    fsx_s3_bucket   = "multi-scale-training-data"
    fsx_auto_export = false
  }

  assert {
    condition     = length(aws_fsx_data_repository_association.s3[0].s3[0].auto_export_policy) == 0
    error_message = "No auto_export_policy may be planned when fsx_auto_export = false (read-only bucket)."
  }

  assert {
    condition     = length(aws_fsx_data_repository_association.s3[0].s3[0].auto_import_policy) == 1
    error_message = "The import policy must remain when fsx_auto_export = false."
  }
}

# 21. Capacity 2000 is neither 1200 nor a multiple of 2400 → variable
#     validation failure (red-proof for the capacity rule).
run "fsx_capacity_2000_rejected" {
  command = plan

  variables {
    enable_fsx               = true
    fsx_s3_bucket            = "multi-scale-training-data"
    fsx_storage_capacity_gib = 2000
  }

  expect_failures = [var.fsx_storage_capacity_gib]
}

# 22. Capacity 2400 (smallest multiple) plans cleanly.
run "fsx_capacity_2400_accepted" {
  command = plan

  variables {
    enable_fsx               = true
    fsx_s3_bucket            = "multi-scale-training-data"
    fsx_storage_capacity_gib = 2400
  }

  assert {
    condition     = aws_fsx_lustre_file_system.data[0].storage_capacity == 2400
    error_message = "2400 GiB is a valid PERSISTENT_2 capacity and must plan cleanly."
  }
}

# 23. Capacity 4800 (larger multiple) plans cleanly.
run "fsx_capacity_4800_accepted" {
  command = plan

  variables {
    enable_fsx               = true
    fsx_s3_bucket            = "multi-scale-training-data"
    fsx_storage_capacity_gib = 4800
  }

  assert {
    condition     = aws_fsx_lustre_file_system.data[0].storage_capacity == 4800
    error_message = "4800 GiB is a valid PERSISTENT_2 capacity and must plan cleanly."
  }
}

# 24. Throughput 300 is not a PERSISTENT_2 tier → variable validation failure.
run "fsx_throughput_300_rejected" {
  command = plan

  variables {
    enable_fsx              = true
    fsx_s3_bucket           = "multi-scale-training-data"
    fsx_per_unit_throughput = 300
  }

  expect_failures = [var.fsx_per_unit_throughput]
}

# 25. enable_fsx without a bucket → the cross-variable validation demands
#     fsx_s3_bucket (red-proof for the required-when-enabled rule).
run "fsx_enabled_without_bucket_rejected" {
  command = plan

  variables {
    enable_fsx = true
  }

  expect_failures = [var.fsx_s3_bucket]
}

# 26. The bucket must be a bare name — an s3:// URI is rejected at the
#     variable boundary (the stack adds the s3:// prefix itself).
run "fsx_bucket_uri_rejected" {
  command = plan

  variables {
    enable_fsx    = true
    fsx_s3_bucket = "s3://multi-scale-training-data"
  }

  expect_failures = [var.fsx_s3_bucket]
}
