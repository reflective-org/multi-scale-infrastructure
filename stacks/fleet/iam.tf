# Instance IAM role — the fleet's ONLY credentials (R9, R12).
#
# The p5 runtime stack deliberately carries no instance role; this stack
# inverts that (KTD4): the containers must pull an image and move data
# through S3 without any long-lived credentials on the boxes, so the role
# grants exactly the enumerated set below and nothing else:
#
#   - ecr:GetAuthorizationToken on * (API constraint — the action cannot be
#     resource-scoped) plus the three pull actions on the ONE repository ARN
#     derived from the image URI — and only when the URI is private ECR.
#   - s3:ListBucket on the bucket, s3:GetObject bucket-wide.
#   - s3:PutObject / multipart actions ONLY under <bucket>/<output_prefix>/*.
#   - the three logs: write actions on the fleet log group, only while
#     enable_container_logs is true (R8).
#
# Policies are standalone aws_iam_role_policy resources: the embedded
# inline_policy / managed_policy_arns arguments are deprecated in provider
# 6.x (KTD4). ARNs use the "aws" partition literally, matching the sample
# policy in docs/admin-access.md — GovCloud/China are out of scope.

# Account id for the log-group ARN — the only grant whose ARN needs it
# (bucket ARNs are partition-global, the repository ARN carries the account
# from the image URI itself).
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "fleet" {
  name_prefix = "${local.name_prefix}-" # KTD10: never collides with a p5 runtime deployment
  description = "Instance role for the multi-scale fleet: ECR pull, S3 data plane, container logs."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EC2AssumeRole"
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { Service = "ec2.amazonaws.com" }
      },
    ]
  })

  tags = local.tags
}

# Referencing the role by resource attribute (not by name string) keeps the
# dependency graph ordered: profile after role, policies after role.
resource "aws_iam_instance_profile" "fleet" {
  name_prefix = "${local.name_prefix}-" # KTD10
  role        = aws_iam_role.fleet.name

  tags = local.tags
}

# ECR pull — exists only when the image URI is private ECR (KTD7/R6). The
# repository ARN comes from the URI (region and account included), so a
# us-west-2 image pulled by a us-east-2 fleet is scoped correctly.
resource "aws_iam_role_policy" "ecr_pull" {
  count = local.is_ecr ? 1 : 0

  name_prefix = "ecr-pull-"
  role        = aws_iam_role.fleet.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthTokenApiConstraint"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPullThisRepositoryOnly"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
        ]
        Resource = local.ecr_repository_arn
      },
    ]
  })
}

# S3 data plane: read anywhere in the bucket, write ONLY under the output
# prefix. Inputs must live outside the prefix — see var.s3_output_prefix.
locals {
  s3_bucket_arn = "arn:aws:s3:::${var.s3_bucket}"
}

resource "aws_iam_role_policy" "s3_data" {
  name_prefix = "s3-data-"
  role        = aws_iam_role.fleet.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ListBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = local.s3_bucket_arn
      },
      {
        Sid      = "S3ReadBucketWide"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${local.s3_bucket_arn}/*"
      },
      {
        Sid    = "S3WriteOutputPrefixOnly"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${local.s3_bucket_arn}/${var.s3_output_prefix}/*"
      },
    ]
  })
}

# Container logs (R8). The log group is Terraform-managed rather than
# driver-created (awslogs-create-group is deliberately NOT set at boot): with
# up to 64 nodes booting at once, per-node CreateLogGroup calls against the
# same name race CloudWatch's rate limits — a throttled loser would trip the
# boot script's loud-failure path over pure setup noise. Managing it here
# also keeps the group in state (destroy removes it — the runbook says to
# read/export logs BEFORE teardown) and drops logs:CreateLogGroup from the
# grant entirely.
resource "aws_cloudwatch_log_group" "fleet" {
  count = var.enable_container_logs ? 1 : 0

  name = local.log_group_name

  tags = local.tags
}

# The two write actions the awslogs driver needs against the existing group,
# scoped to the fleet's log group rather than *. Removed entirely when logs
# are disabled.
resource "aws_iam_role_policy" "container_logs" {
  count = var.enable_container_logs ? 1 : 0

  name_prefix = "container-logs-"
  role        = aws_iam_role.fleet.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteFleetLogGroupOnly"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = [
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}",
          "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}:*",
        ]
      },
    ]
  })
}
