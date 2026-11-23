# Instance role: SSM Session Manager and Run Command only. The automation's
# own credentials (GitHub App, Slack, Claude) live in GitHub Actions secrets
# and reach the runner per job; the instance role grants no other AWS access.

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name_prefix        = "${local.name_prefix}-"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name_prefix = "${local.name_prefix}-"
  role        = aws_iam_role.host.name

  tags = local.tags
}
