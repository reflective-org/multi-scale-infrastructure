# Fleet stack tests — plan-only against a fully mocked AWS provider.
# No run here ever touches a real AWS account.

mock_provider "aws" {
  override_data {
    target = data.aws_ip_ranges.ec2_instance_connect
    values = {
      cidr_blocks = ["18.206.107.24/29"]
    }
  }

  # Deterministic account id so log-group ARN assertions can be exact.
  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  # Deterministic AMI id for the SSM-resolved DLAMI (mirrors the runtime
  # stack's test mock).
  override_data {
    target = data.aws_ssm_parameter.dlami
    values = {
      value = "ami-0123456789abcdef0"
    }
  }
}

variables {
  region       = "us-east-1"
  public_key   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderPublicKeyForTests test@example"
  docker_image = "ghcr.io/example/train:v1"
  s3_bucket    = "example-training-data"
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

# ---------------------------------------------------------------------------
# U2: instance IAM role and scoped policies (R6, R8, R9 / KTD4, KTD7, KTD10)
# ---------------------------------------------------------------------------

# 12. A private-ECR image plans exactly one pull policy whose repository ARN
#     carries the REGION AND ACCOUNT FROM THE URI — var.region is deliberately
#     different (us-east-2) to prove cross-region scoping (AE2 policy half).
#     The policy's total action set is exactly the KTD4 enumeration: the three
#     pull actions on the repository, GetAuthorizationToken on * (API
#     constraint), nothing else (R9).
run "ecr_pull_policy_scoped_to_uri_region" {
  command = plan

  variables {
    region       = "us-east-2"
    docker_image = "111122223333.dkr.ecr.us-west-2.amazonaws.com/train:v3"
  }

  assert {
    condition     = length(aws_iam_role_policy.ecr_pull) == 1
    error_message = "A private-ECR image must plan exactly one ECR pull policy."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.ecr_pull[0].policy).Statement[0].Action == "ecr:GetAuthorizationToken" && jsondecode(aws_iam_role_policy.ecr_pull[0].policy).Statement[0].Resource == "*"
    error_message = "GetAuthorizationToken must be granted on * — the action cannot be resource-scoped (KTD4 API constraint)."
  }

  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.ecr_pull[0].policy).Statement[1].Action) == toset(["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"])
    error_message = "The pull statement must grant exactly the three ECR pull actions."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.ecr_pull[0].policy).Statement[1].Resource == "arn:aws:ecr:us-west-2:111122223333:repository/train"
    error_message = "The pull statement must target the repository ARN derived from the image URI — region us-west-2 from the URI, never var.region (us-east-2 here)."
  }

  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_role_policy.ecr_pull[0].policy).Statement : flatten([s.Action])])) == toset(["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"])
    error_message = "The ECR policy must grant exactly the enumerated action set and nothing else (R9)."
  }
}

# 13. Digest-pinned nested URI — the runbook's recommended shape, so the
#     PRIMARY parse case: everything from the first "@" is the ref ("@" is
#     never valid inside a repository path); the nested path keeps its slash.
#     (Red-proofed: a tag-only strip left "...repository/org/train@sha256".)
run "ecr_digest_pinned_nested_uri_derives_repository_arn" {
  command = plan

  variables {
    docker_image = "111122223333.dkr.ecr.us-west-2.amazonaws.com/org/train@sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.ecr_pull[0].policy).Statement[1].Resource == "arn:aws:ecr:us-west-2:111122223333:repository/org/train"
    error_message = "A digest-pinned nested URI must derive the repository ARN with the @sha256:<digest> ref stripped (repository/org/train)."
  }
}

# 14. Nested tagged URI — the tag colon appears after the final "/" and only
#     that colon is stripped; the repository path keeps its slashes.
run "ecr_nested_tagged_uri_derives_repository_arn" {
  command = plan

  variables {
    docker_image = "111122223333.dkr.ecr.us-west-2.amazonaws.com/team/train:v3"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.ecr_pull[0].policy).Statement[1].Resource == "arn:aws:ecr:us-west-2:111122223333:repository/team/train"
    error_message = "A nested tagged URI must strip only the :tag after the final slash (repository/team/train)."
  }
}

# 15. Ref-less URI (no tag, no digest) — the path is already the repository.
run "ecr_untagged_uri_derives_repository_arn" {
  command = plan

  variables {
    docker_image = "111122223333.dkr.ecr.us-west-2.amazonaws.com/train"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.ecr_pull[0].policy).Statement[1].Resource == "arn:aws:ecr:us-west-2:111122223333:repository/train"
    error_message = "A ref-less ECR URI must map straight to its repository ARN."
  }
}

# 16. Public registry (file default ghcr.io) → zero ECR policy resources and
#     no ecr: action anywhere else; the role and profile still plan (AE2
#     negative half). The role's policy surface is then S3 + logs only.
run "public_registry_gets_no_ecr_policy" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.ecr_pull) == 0
    error_message = "A non-ECR registry must plan zero ECR pull policies (KTD7)."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.s3_data.policy, "ecr:") && !strcontains(aws_iam_role_policy.container_logs[0].policy, "ecr:")
    error_message = "No ecr: action may leak into the S3 or logs policies."
  }

  assert {
    condition     = aws_iam_role.fleet.name_prefix == "multi-scale-fleet-" && aws_iam_instance_profile.fleet.name_prefix == "multi-scale-fleet-"
    error_message = "Role and instance profile must still be planned (fleet-prefixed) for a public-registry fleet."
  }
}

# 17. public.ecr.aws is a PUBLIC registry despite the name — KTD7 calls it out
#     explicitly: no ECR grant (public pulls need no auth).
run "public_ecr_aws_gets_no_ecr_policy" {
  command = plan

  variables {
    docker_image = "public.ecr.aws/org/train:v3"
  }

  assert {
    condition     = length(aws_iam_role_policy.ecr_pull) == 0
    error_message = "public.ecr.aws is not private ECR — no ECR pull policy may be planned (KTD7)."
  }
}

# 18. S3 scoping (AE5): list on the bucket, read bucket-wide, and EVERY
#     statement carrying a write action confined to <bucket>/<prefix>/* —
#     asserted as a sweep over the policy, not just the authored statement,
#     plus exact-set equality on the policy's total action grant (R9).
run "s3_write_confined_to_output_prefix" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role_policy.s3_data.policy).Statement[0].Action == "s3:ListBucket" && jsondecode(aws_iam_role_policy.s3_data.policy).Statement[0].Resource == "arn:aws:s3:::example-training-data"
    error_message = "ListBucket must target the bucket ARN itself."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.s3_data.policy).Statement[1].Action == "s3:GetObject" && jsondecode(aws_iam_role_policy.s3_data.policy).Statement[1].Resource == "arn:aws:s3:::example-training-data/*"
    error_message = "GetObject must stay bucket-wide (R9: inputs are readable anywhere)."
  }

  assert {
    condition     = toset(flatten([jsondecode(aws_iam_role_policy.s3_data.policy).Statement[2].Action])) == toset(["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]) && jsondecode(aws_iam_role_policy.s3_data.policy).Statement[2].Resource == "arn:aws:s3:::example-training-data/outputs/*"
    error_message = "The write statement must grant exactly the three write actions under <bucket>/outputs/* (the default prefix)."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.s3_data.policy).Statement :
      alltrue([for r in flatten([s.Resource]) : endswith(r, "/outputs/*")])
      if length(setintersection(toset(flatten([s.Action])), toset(["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]))) > 0
    ])
    error_message = "Write actions may appear ONLY in statements whose every resource is under the output prefix (AE5)."
  }

  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_role_policy.s3_data.policy).Statement : flatten([s.Action])])) == toset(["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"])
    error_message = "The S3 policy must grant exactly the enumerated action set and nothing else (R9)."
  }
}

# 19. A custom nested prefix flows verbatim into the write ARN.
run "s3_write_follows_custom_nested_prefix" {
  command = plan

  variables {
    s3_output_prefix = "runs/2026-09"
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.s3_data.policy).Statement[2].Resource == "arn:aws:s3:::example-training-data/runs/2026-09/*"
    error_message = "A nested output prefix must scope the write grant to <bucket>/runs/2026-09/*."
  }
}

# 20. Logs on by default (R8): one policy granting exactly the three write
#     actions, scoped to the fleet log group's ARN pair — never * (account id
#     is the mocked caller identity, region is var.region).
run "logs_grant_present_and_group_scoped_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.container_logs) == 1
    error_message = "enable_container_logs defaults to true and must plan the logs policy."
  }

  assert {
    condition     = toset(flatten([jsondecode(aws_iam_role_policy.container_logs[0].policy).Statement[0].Action])) == toset(["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"])
    error_message = "The logs statement must grant exactly the three write actions the awslogs driver needs."
  }

  assert {
    condition = toset(flatten([jsondecode(aws_iam_role_policy.container_logs[0].policy).Statement[0].Resource])) == toset([
      "arn:aws:logs:us-east-1:123456789012:log-group:/multi-scale-fleet/containers",
      "arn:aws:logs:us-east-1:123456789012:log-group:/multi-scale-fleet/containers:*",
    ])
    error_message = "The logs grant must be scoped to the fleet log group's ARN pair, never *."
  }
}

# 21. Logs off → the logs policy (and with it every logs: action on the role)
#     disappears; the S3 policy is untouched (AE5 half, R8 toggle).
run "logs_disabled_removes_logs_grant" {
  command = plan

  variables {
    enable_container_logs = false
  }

  assert {
    condition     = length(aws_iam_role_policy.container_logs) == 0
    error_message = "enable_container_logs = false must remove the logs policy entirely."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.s3_data.policy, "logs:")
    error_message = "No logs: action may hide in the S3 policy when logs are disabled."
  }
}

# 22. Role/profile shape: EC2 trust only, fleet name prefix on both (KTD10),
#     profile wired to the role resource (graph ordering by attribute).
run "role_trusts_ec2_and_uses_fleet_prefix" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.fleet.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com" && jsondecode(aws_iam_role.fleet.assume_role_policy).Statement[0].Action == "sts:AssumeRole"
    error_message = "The role must trust exactly the EC2 service principal."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.fleet.assume_role_policy).Statement) == 1
    error_message = "The trust policy must carry a single EC2 statement — no other principals."
  }

  assert {
    condition     = aws_iam_role.fleet.name_prefix == "multi-scale-fleet-" && aws_iam_instance_profile.fleet.name_prefix == "multi-scale-fleet-"
    error_message = "Role and instance profile must use the fleet-specific name prefix (KTD10)."
  }
}

# 23. Leading/trailing slashes in the output prefix are rejected at the
#     variable boundary — a leading slash would silently widen or break the
#     write ARN. (Red-proofed: before the validation landed, this run failed
#     with "Missing expected failure".)
run "output_prefix_with_slashes_rejected" {
  command = plan

  variables {
    s3_output_prefix = "/bad/"
  }

  expect_failures = [var.s3_output_prefix]
}

# 24. Empty prefix → rejected (an empty prefix would grant writes under
#     "<bucket>//*").
run "output_prefix_empty_rejected" {
  command = plan

  variables {
    s3_output_prefix = ""
  }

  expect_failures = [var.s3_output_prefix]
}

# 25. Trailing slash alone → rejected (would double the separator in the ARN).
run "output_prefix_trailing_slash_rejected" {
  command = plan

  variables {
    s3_output_prefix = "bad/"
  }

  expect_failures = [var.s3_output_prefix]
}

# 26. docker_image is required non-empty — whitespace does not count.
run "blank_docker_image_rejected" {
  command = plan

  variables {
    docker_image = "   "
  }

  expect_failures = [var.docker_image]
}

# 27. s3_bucket must be a bare bucket name — an s3:// URI (or any path) is
#     rejected at the boundary, mirroring the runtime stack's fsx shape.
run "s3_uri_bucket_rejected" {
  command = plan

  variables {
    s3_bucket = "s3://example-training-data"
  }

  expect_failures = [var.s3_bucket]
}

# ---------------------------------------------------------------------------
# U3: fleet instances (R1, R3, R11 / KTD5, KTD6, KTD9)
#
# NOTE (KTD5, R11 — documented, not fabricated): the replacement-on-change
# contract (user_data_replace_on_change = true, no ignore_changes, no
# create_before_destroy) is APPLY-TIME behavior that a plan-only mock cannot
# regression-test — there is no prior state to diff against, so no run here
# can observe a "replace" action. Run 32 asserts the ARGUMENT is set; the
# behavior itself is enforced by provider semantics.
#
# NOTE (KTD9, AE1 spread — documented, not fabricated): the round-robin
# subnet ALTERNATION (element() over the per-AZ subnet ids) is likewise not
# regression-testable here: subnet ids are computed attributes, unknown at
# plan under the mock; override_resource cannot target an indexed instance
# ("Resource instance address with keys is not allowed"), so the two subnets
# cannot be given distinct mock ids; and a mock apply generates the SAME id
# for every instance of a resource (observed: both subnets got
# "GcX0E6TRLUkLq1j"), which would make an alternation assertion vacuously
# true. Run 28 asserts what IS real at plan: the instance count, and the
# per-index shard identity that AE1 pairs with the spread.
# ---------------------------------------------------------------------------

# 28. instance_count = 4 with the default two subnets → four instances, each
#     carrying its own index in Name tag and shard env (AE1; spread half
#     documented above).
run "four_instances_planned_with_two_subnets" {
  command = plan

  variables {
    instance_count = 4
  }

  assert {
    condition     = length(aws_instance.fleet) == 4
    error_message = "instance_count = 4 must plan exactly four instances."
  }

  assert {
    condition     = length(aws_subnet.public) == 2
    error_message = "The default subnet_azs must still plan two subnets alongside the instances."
  }

  assert {
    condition     = alltrue([for i, inst in aws_instance.fleet : inst.tags["Name"] == "multi-scale-fleet-${i}"])
    error_message = "Every instance must be tagged Name = <prefix>-<index>."
  }
}

# 29. Pause (R3, AE4): instance_count = 0 → zero instances while VPC, SG,
#     key pair, role, and instance profile all still plan.
run "pause_keeps_network_role_and_key" {
  command = plan

  variables {
    instance_count = 0
  }

  assert {
    condition     = length(aws_instance.fleet) == 0
    error_message = "instance_count = 0 must plan zero instances (the pause mechanism)."
  }

  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16" && length(aws_subnet.public) == 2
    error_message = "The VPC and subnets must persist through a pause."
  }

  assert {
    condition     = aws_security_group.fleet.name_prefix == "multi-scale-fleet-" && length(aws_key_pair.this) == 1
    error_message = "Security group and key pair must persist through a pause."
  }

  assert {
    condition     = aws_iam_role.fleet.name_prefix == "multi-scale-fleet-" && aws_iam_instance_profile.fleet.name_prefix == "multi-scale-fleet-"
    error_message = "Role and instance profile must persist through a pause."
  }
}

# 30. Explicit ami_id bypasses SSM entirely (KTD6 escape hatch).
run "explicit_ami_id_bypasses_ssm" {
  command = plan

  variables {
    ami_id = "ami-0fedcba9876543210"
  }

  assert {
    condition     = length(data.aws_ssm_parameter.dlami) == 0
    error_message = "Setting ami_id must plan zero SSM parameter lookups."
  }

  assert {
    condition     = aws_instance.fleet[0].ami == "ami-0fedcba9876543210"
    error_message = "The instance must run exactly the pinned AMI."
  }
}

# 31. Default AMI resolution: the AL2023 Base GPU DLAMI SSM path — asserted
#     on the data source's CONFIGURED name, which is real at plan (KTD6; no
#     ami_flavor — the AL2 DLAMI is frozen and the fleet has no legacy).
run "default_ami_resolves_al2023_gpu_ssm_path" {
  command = plan

  assert {
    condition     = length(data.aws_ssm_parameter.dlami) == 1
    error_message = "The default configuration must resolve the AMI via one SSM lookup."
  }

  assert {
    condition     = data.aws_ssm_parameter.dlami[0].name == "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
    error_message = "The SSM path must be the AL2023 Base GPU DLAMI parameter (KTD6)."
  }
}

# 32. Hardening and lifecycle arguments (mirrors the runtime assertions):
#     IMDSv2 required with hop limit 2 (containers reach IMDS through
#     docker's NAT hop), encrypted gp3 root at the validated minimum size,
#     and the KTD5 replacement argument set — see the NOTE above for why
#     only the argument, not the replace behavior, is assertable.
run "imdsv2_encrypted_root_and_replacement_argument" {
  command = plan

  assert {
    condition     = aws_instance.fleet[0].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required (http_tokens = required)."
  }

  assert {
    condition     = aws_instance.fleet[0].metadata_options[0].http_endpoint == "enabled" && aws_instance.fleet[0].metadata_options[0].http_put_response_hop_limit == 2
    error_message = "IMDS must be enabled with hop limit 2 so the container can reach it through docker's NAT hop."
  }

  assert {
    condition     = aws_instance.fleet[0].root_block_device[0].volume_type == "gp3" && aws_instance.fleet[0].root_block_device[0].encrypted && aws_instance.fleet[0].root_block_device[0].volume_size == 100
    error_message = "Root volume must be encrypted gp3 at the default 100 GiB."
  }

  assert {
    condition     = aws_instance.fleet[0].user_data_replace_on_change == true
    error_message = "user_data changes must REPLACE instances (KTD5) — never in-place update, never ignored."
  }

  assert {
    condition     = aws_instance.fleet[0].instance_type == "g6e.xlarge"
    error_message = "The default instance type must be g6e.xlarge (R1)."
  }
}

# 33. instance_count above the 0-64 bound → rejected at the variable
#     boundary. (Red-proofed: with the validation removed, this run failed
#     with "Missing expected failure".)
run "instance_count_above_bound_rejected" {
  command = plan

  variables {
    instance_count = 65
  }

  expect_failures = [var.instance_count]
}

# 34. Negative instance_count → rejected.
run "negative_instance_count_rejected" {
  command = plan

  variables {
    instance_count = -1
  }

  expect_failures = [var.instance_count]
}

# 35. Root volume below the DLAMI's 100 GiB headroom → rejected.
run "small_root_volume_rejected" {
  command = plan

  variables {
    root_volume_size_gib = 50
  }

  expect_failures = [var.root_volume_size_gib]
}

# ---------------------------------------------------------------------------
# U4: container runtime user_data (R4-R8, R12 / KTD3, KTD7, KTD8)
# The rendered user_data is fully known at plan (all template inputs are
# variables and locals), so every assertion here is on the real script text.
# ---------------------------------------------------------------------------

# 36. Shard identity (AE1 env half): node 2 of 4 carries exactly
#     NODE_INDEX=2 / NODE_COUNT=4 as whole env-file lines.
run "user_data_carries_shard_identity" {
  command = plan

  variables {
    instance_count = 4
  }

  assert {
    condition     = can(regex("\nNODE_INDEX=2\n", aws_instance.fleet[2].user_data)) && can(regex("\nNODE_COUNT=4\n", aws_instance.fleet[2].user_data))
    error_message = "Node 2's user_data must carry NODE_INDEX=2 and NODE_COUNT=4 as env-file lines."
  }

  assert {
    condition     = can(regex("\nNODE_INDEX=0\n", aws_instance.fleet[0].user_data))
    error_message = "NODE_INDEX must be 0-based (node 0 carries NODE_INDEX=0)."
  }
}

# 37. ECR image → login block present with the URI's region (us-west-2)
#     while var.region is deliberately us-east-2 (R6, KTD7): login
#     authenticates against the REGISTRY's region, awslogs ships to the
#     FLEET's region. --gpus all stays explicit (KTD3).
run "ecr_image_renders_login_block_with_uri_region" {
  command = plan

  variables {
    region       = "us-east-2"
    docker_image = "111122223333.dkr.ecr.us-west-2.amazonaws.com/train:v3"
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "aws ecr get-login-password --region us-west-2")
    error_message = "The ECR login must use the region parsed from the image URI (us-west-2), never var.region."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "docker login --username AWS --password-stdin 111122223333.dkr.ecr.us-west-2.amazonaws.com")
    error_message = "docker login must target the registry host from the image URI."
  }

  assert {
    condition     = !strcontains(aws_instance.fleet[0].user_data, "get-login-password --region us-east-2")
    error_message = "var.region (us-east-2) must never leak into the ECR login."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--log-opt awslogs-region=us-east-2")
    error_message = "awslogs-region must stay the FLEET's region (us-east-2) even for a cross-region image."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--gpus all")
    error_message = "--gpus all must be explicit in every rendering (KTD3)."
  }
}

# 38. Public image (the file default ghcr.io) → no login block at all (R6).
run "public_image_renders_no_login_block" {
  command = plan

  assert {
    condition     = !strcontains(aws_instance.fleet[0].user_data, "get-login-password") && !strcontains(aws_instance.fleet[0].user_data, "docker login")
    error_message = "A public-registry image must render no ECR login block."
  }
}

# 39. Restart default (R5): bounded on-failure retries — a shard that exits
#     0 is never re-run, a crashing one retries at most 3 times.
run "default_restart_is_bounded_on_failure" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--restart on-failure:3")
    error_message = "The default restart policy must render --restart on-failure:3 (R5 bounded retries)."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--gpus all")
    error_message = "--gpus all must be explicit in the default rendering (KTD3)."
  }
}

# 40. restart_max_retries flows into the on-failure bound.
run "restart_retries_seven" {
  command = plan

  variables {
    restart_max_retries = 7
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--restart on-failure:7")
    error_message = "restart_max_retries = 7 must render --restart on-failure:7."
  }
}

# 41. unless-stopped renders bare (retries ignored) — the variable's
#     description warns it re-runs completed shards on reboot.
run "restart_unless_stopped_renders_bare" {
  command = plan

  variables {
    restart_policy = "unless-stopped"
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--restart unless-stopped") && !strcontains(aws_instance.fleet[0].user_data, "on-failure")
    error_message = "unless-stopped must render bare --restart unless-stopped with restart_max_retries ignored."
  }
}

# 42. none renders bare.
run "restart_none_renders_bare" {
  command = plan

  variables {
    restart_policy = "none"
  }

  assert {
    condition     = can(regex("\n  --restart none \\\\\n", aws_instance.fleet[0].user_data))
    error_message = "restart_policy = none must render bare --restart none."
  }
}

# 43. Logs disabled → not one awslogs byte in the rendered script (R8
#     toggle; the IAM half is run 21).
run "logs_disabled_removes_awslogs_flags" {
  command = plan

  variables {
    enable_container_logs = false
  }

  assert {
    condition     = !strcontains(aws_instance.fleet[0].user_data, "awslogs") && !strcontains(aws_instance.fleet[0].user_data, "--log-driver")
    error_message = "enable_container_logs = false must render no awslogs flags at all."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--gpus all") && strcontains(aws_instance.fleet[0].user_data, "--restart on-failure:3")
    error_message = "Disabling logs must not disturb the rest of the run command."
  }
}

# 44. Logs enabled (default): the full awslogs flag set, including
#     awslogs-region — REQUIRED by docker, the driver does not infer the
#     instance region — and a per-node stream so restarts keep appending to
#     one stream per node.
run "logs_enabled_renders_full_awslogs_flag_set" {
  command = plan

  variables {
    instance_count = 2
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--log-driver awslogs")
    error_message = "The awslogs driver must be selected when logs are enabled."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--log-opt awslogs-group=/multi-scale-fleet/containers")
    error_message = "awslogs-group must be the fleet log group (matches the IAM grant in run 20)."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--log-opt awslogs-region=us-east-1")
    error_message = "awslogs-region is REQUIRED by docker and must be the fleet's region."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--log-opt awslogs-create-group=true")
    error_message = "awslogs-create-group=true must be set — nothing else creates the group."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--log-opt awslogs-stream=multi-scale-fleet-0") && strcontains(aws_instance.fleet[1].user_data, "--log-opt awslogs-stream=multi-scale-fleet-1")
    error_message = "Each node must write its own index-named stream."
  }
}

# 45. Operator env vars pass via the env FILE, never interpolated flags
#     (KTD3): a value with a space and a quote appears literally as one
#     env-file line, and the key appears NOWHERE else in the script.
run "operator_env_passes_via_env_file_literally" {
  command = plan

  variables {
    container_env = {
      DATA_PATH = "s3://bucket/some path"
      MOTTO     = "say \"hi\""
    }
  }

  assert {
    condition     = can(regex("\nDATA_PATH=s3://bucket/some path\n", aws_instance.fleet[0].user_data))
    error_message = "The env-file line must carry the space-containing value literally (env-file format has no quoting semantics)."
  }

  assert {
    condition     = can(regex("\nMOTTO=say \"hi\"\n", aws_instance.fleet[0].user_data))
    error_message = "The env-file line must carry the quote-containing value literally."
  }

  assert {
    condition     = length(regexall("DATA_PATH", aws_instance.fleet[0].user_data)) == 1 && length(regexall("MOTTO", aws_instance.fleet[0].user_data)) == 1
    error_message = "Operator env keys must appear exactly once — in the env file, never as an interpolated -e/--env flag."
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--env-file /etc/fleet/container.env")
    error_message = "docker run must consume the env file."
  }
}

# 46. container_run_args lands between the fixed flags and the image
#     reference (canonical --shm-size case).
run "run_args_between_fixed_flags_and_image" {
  command = plan

  variables {
    container_run_args = "--shm-size=8g"
  }

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "--shm-size=8g ghcr.io/example/train:v1")
    error_message = "container_run_args must sit immediately before the image reference."
  }

  assert {
    condition     = can(regex("(?s)--env-file /etc/fleet/container\\.env.*--restart on-failure:3.*--shm-size=8g ghcr\\.io/example/train:v1", aws_instance.fleet[0].user_data))
    error_message = "container_run_args must come AFTER the fixed flags (env-file, restart) and BEFORE the image."
  }
}

# 47. Default container_run_args = "" → the image line carries no stray
#     token and no doubled whitespace (exact rendered line asserted).
run "default_run_args_leave_no_stray_token" {
  command = plan

  assert {
    condition     = strcontains(aws_instance.fleet[0].user_data, "\n  ghcr.io/example/train:v1 \\\n")
    error_message = "With empty run args the image line must render as exactly \"  <image> \\\" — no stray token, no double space."
  }
}

# 48. A newline inside an env value would break the line-based env-file
#     format → rejected at the variable boundary (R12-adjacent hygiene).
run "newline_env_value_rejected" {
  command = plan

  variables {
    container_env = {
      BAD = "line one\nline two"
    }
  }

  expect_failures = [var.container_env]
}

# 49. A key that is not a valid env name → rejected.
run "invalid_env_key_rejected" {
  command = plan

  variables {
    container_env = {
      "1BAD" = "x"
    }
  }

  expect_failures = [var.container_env]
}

# 50. NODE_INDEX / NODE_COUNT are reserved — an operator override would
#     silently corrupt the shard math (the env file's later line wins).
run "reserved_env_key_rejected" {
  command = plan

  variables {
    container_env = {
      NODE_COUNT = "9"
    }
  }

  expect_failures = [var.container_env]
}
