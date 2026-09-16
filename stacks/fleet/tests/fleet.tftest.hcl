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
