# The runner host: Ubuntu 24.04 on a CPU instance, reachable only through SSM.

locals {
  # Canonical publishes the current Ubuntu 24.04 AMI under this SSM path.
  ubuntu_ssm_path = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"

  # The data volume shows up on Nitro instances as an NVMe device whose serial
  # is the volume ID without its dash; the boot script finds it by that name.
  data_device_id = "nvme-Amazon_Elastic_Block_Store_${replace(aws_ebs_volume.data.id, "-", "")}"
}

data "aws_ssm_parameter" "ubuntu" {
  count = var.ami_id == null ? 1 : 0

  name = local.ubuntu_ssm_path
}

locals {
  # An AMI ID is not a secret; unmark it to keep plan output legible.
  ami_id = var.ami_id != null ? var.ami_id : nonsensitive(one(data.aws_ssm_parameter.ubuntu[*].value))
}

resource "aws_instance" "host" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = true

  # IMDSv2 only, hop limit 1: containers on this host (the agent runs model
  # code in them) must not reach instance metadata or the instance role.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # The root volume holds only the OS and installed tools; the addition
  # working folders live on the data volume (storage.tf).
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.tags, { Name = "${local.name_prefix}-root" })
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    data_device_id = local.data_device_id
    runner_version = var.runner_version
    runner_sha256  = var.runner_sha256
  })
  user_data_replace_on_change = false

  tags = merge(local.tags, { Name = local.name_prefix })

  lifecycle {
    # The SSM path always points at the newest Ubuntu image, and cloud-init
    # runs only at first boot: neither a new AMI release nor an edited boot
    # script should replace or restart a running host. A host built from
    # current config needs `tofu apply -replace=aws_instance.host` (the data
    # volume survives it; see docs/model-additions.md).
    #
    # A stopped instance releases its public IP, and AWS then reports
    # associate_public_ip_address = false. That attribute forces replacement, so
    # without ignoring it, stopping or starting the host (`running`) would
    # rebuild it.
    ignore_changes = [ami, user_data, associate_public_ip_address]
  }
}

# On between additions: off. Stopping keeps the root and data volumes and
# bills only for storage. See docs/model-additions.md for when it is safe.
resource "aws_ec2_instance_state" "host" {
  instance_id = aws_instance.host.id
  state       = var.running ? "running" : "stopped"
}
