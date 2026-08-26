# GPU instances launched into the capacity block (R3, R4, R6 package half,
# R10/KTD9). The reservation data source in main.tf supplies the instance
# type, state, and total size — the operator is never asked twice.

locals {
  # Deep Learning Base OSS NVIDIA Driver AMI SSM paths (KTD3). The AL2023
  # path's extra "-gpu" segment is deliberate — AWS's published paths differ
  # between the two generations. NOTE: the AL2 DLAMI is frozen at its final
  # release (AL2 end of life, June 2026); ami_flavor = "al2023" is the
  # patched alternative.
  dlami_ssm_path = {
    al2    = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-amazon-linux-2/latest/ami-id"
    al2023 = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
  }
}

# AMI resolution (R4/KTD3): resolved via SSM by flavor unless the operator
# pins an explicit ami_id, which bypasses SSM entirely.
data "aws_ssm_parameter" "dlami" {
  count = var.ami_id == null ? 1 : 0

  name = local.dlami_ssm_path[var.ami_flavor]
}

locals {
  # SSM parameter values are provider-marked sensitive; an AMI ID is not a
  # secret, so unmark it to keep plan output legible.
  ami_id = var.ami_id != null ? var.ami_id : nonsensitive(one(data.aws_ssm_parameter.dlami[*].value))
}

resource "aws_instance" "gpu" {
  count = var.launch_instance ? var.instance_count : 0

  ami = local.ami_id
  # The reservation dictates the instance type (R3) — asking for it again
  # would only create a mismatch opportunity.
  instance_type = data.aws_ec2_capacity_block_reservation.this.instance_type

  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.gpu.id]
  key_name                    = local.key_pair_name
  associate_public_ip_address = true

  # Both halves are required to land inside the block: capacity-block is a
  # distinct market type, and the target pins the exact reservation (R3).
  instance_market_options {
    market_type = "capacity-block"
  }

  capacity_reservation_specification {
    capacity_reservation_target {
      capacity_reservation_id = var.capacity_reservation_id
    }
  }

  # IMDSv2 only; hop limit 2 so containerized workloads on the instance can
  # still reach instance metadata.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # The root volume dies with the instance when the block ends — only /data
  # (FSx -> S3, U5) survives. See docs/runbooks.md.
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.tags, { Name = "${local.name_prefix}-${count.index}-root" })
  }

  # fsx_mount_snippet is owned by fsx.tf (U5): the conditional Lustre client
  # install + /data mount fragment, empty while enable_fsx = false.
  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    fsx_mount_snippet = local.fsx_mount_snippet
  })
  # user_data is IGNORED after creation (lifecycle ignore_changes below):
  # changing enable_fsx neither replaces nor stop/starts running instances,
  # and does not mount /data on them — mount manually per runbook 7
  # (docs/runbooks.md). A NEW instance created later (count increase or
  # replacement) still renders the CURRENT configuration.
  user_data_replace_on_change = false

  tags = merge(local.tags, { Name = "${local.name_prefix}-${count.index}" })

  lifecycle {
    # Without this, a user_data diff (enable_fsx flipping local.fsx_mount_snippet)
    # would apply as an in-place update that STOPS and STARTS every running
    # instance — and cloud-init never re-runs, so /data still wouldn't mount.
    # ignore_changes only affects updates: creates always render current config.
    ignore_changes = [user_data]

    # KTD9: pre-activation provisioning is a feature — fail legibly instead
    # of letting AWS reject the launch with an opaque API error (AE5).
    precondition {
      condition     = data.aws_ec2_capacity_block_reservation.this.state == "active"
      error_message = "Capacity block ${var.capacity_reservation_id} is \"${data.aws_ec2_capacity_block_reservation.this.state}\", not \"active\" — instances can only launch after the block's start time. Wait for the start time, or set launch_instance = false to pre-provision networking and FSx now (see docs/runbooks.md)."
    }

    # Compared against the block's TOTAL size, not available_instance_count:
    # our own running instances decrement the available counter, which would
    # wedge every post-launch plan. AWS itself rejects true launch-time
    # capacity races.
    precondition {
      condition     = var.instance_count <= data.aws_ec2_capacity_block_reservation.this.instance_count
      error_message = "instance_count (${var.instance_count}) exceeds the total size of capacity block ${var.capacity_reservation_id} (${data.aws_ec2_capacity_block_reservation.this.instance_count} instance(s))."
    }
  }
}

# Under-subscription is legal but expensive: the whole block is paid upfront
# whether or not every reserved instance is launched (R10). Warn, don't
# block — partial use can be deliberate.
check "capacity_block_under_subscribed" {
  # Total size again (same rationale as the launch precondition): comparing
  # against the remaining counter would misfire once our instances run.
  assert {
    condition     = !var.launch_instance || var.instance_count >= data.aws_ec2_capacity_block_reservation.this.instance_count
    error_message = "instance_count (${var.instance_count}) is below the ${data.aws_ec2_capacity_block_reservation.this.instance_count} instance(s) capacity block ${var.capacity_reservation_id} holds — the unused capacity is already paid for and cannot be refunded."
  }
}
