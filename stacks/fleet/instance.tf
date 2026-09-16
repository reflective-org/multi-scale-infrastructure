# Fleet GPU instances (R1, R3, R11 / KTD5, KTD6, KTD9): X plain on-demand
# nodes — no capacity block, no reservation machinery — each booting exactly
# one container via the user_data template rendered below. instance_count = 0
# is the documented pause mechanism (R3): networking, security group, key
# pair, and role all persist while nothing bills by the hour.

# AMI resolution (KTD6): the AL2023 Base GPU Deep Learning AMI via SSM —
# same mechanism as the runtime stack — unless the operator pins an explicit
# ami_id, which bypasses SSM entirely. No ami_flavor here: the AL2 DLAMI is
# frozen at its final release (AL2 end of life, June 2026) and a new fleet
# has no legacy to serve.
data "aws_ssm_parameter" "dlami" {
  count = var.ami_id == null ? 1 : 0

  name = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
}

locals {
  # SSM parameter values are provider-marked sensitive; an AMI ID is not a
  # secret, so unmark it to keep plan output legible.
  ami_id = var.ami_id != null ? var.ami_id : nonsensitive(one(data.aws_ssm_parameter.dlami[*].value))

  # Fixed container name, identical on every node (KTD3) — each node runs
  # exactly one container, so there is nothing to disambiguate, and a fixed
  # name gives the runbook a stable handle (docker logs/inspect fleet-job).
  container_name = "fleet-job"

  # --restart spec (R5): bounded retries for on-failure; the other two
  # policies take no retry count (restart_max_retries is ignored for them —
  # said on both variables). Docker's spelling of "never restart" is `no`,
  # so the operator-facing "none" maps to it here.
  restart_spec = var.restart_policy == "on-failure" ? "on-failure:${var.restart_max_retries}" : (var.restart_policy == "none" ? "no" : var.restart_policy)
}

resource "aws_instance" "fleet" {
  count = var.instance_count

  ami           = local.ami_id
  instance_type = var.instance_type

  # KTD9: element() wraps natively, so instances spread round-robin across
  # the per-AZ public subnets with no explicit modulo.
  subnet_id                   = element(aws_subnet.public[*].id, count.index)
  vpc_security_group_ids      = [aws_security_group.fleet.id]
  key_name                    = local.key_pair_name
  iam_instance_profile        = aws_iam_instance_profile.fleet.name
  associate_public_ip_address = true

  # IMDSv2 only; hop limit 2 so the CONTAINER can still reach instance
  # metadata through docker's NAT hop — the awslogs driver and any AWS SDK
  # inside the container both need the role credentials from IMDS.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gib
    encrypted             = true
    delete_on_termination = true

    tags = merge(local.tags, { Name = "${local.name_prefix}-${count.index}-root" })
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    node_index            = count.index
    node_count            = var.instance_count
    container_env         = var.container_env
    docker_image          = var.docker_image
    container_name        = local.container_name
    restart_spec          = local.restart_spec
    enable_container_logs = var.enable_container_logs
    log_group_name        = local.log_group_name
    region                = var.region
    # Per-node stream name: restarts of the container keep appending to ONE
    # stream per node instead of scattering across auto-generated streams.
    log_stream = "${local.name_prefix}-${count.index}"
    is_ecr     = local.is_ecr
    ecr_region = local.ecr_region
    # trimspace so the default container_run_args = "" leaves no stray
    # token (or double space) in front of the image reference.
    ecr_registry_host = local.ecr_registry_host
    run_tail          = trimspace("${var.container_run_args} ${var.docker_image}")
  })

  # ==========================================================================
  # REPLACEMENT IS THE DEPLOYMENT MECHANISM (R11, KTD5) — READ BEFORE "FIXING"
  #
  # This is the exact INVERSE of the p5 runtime stack, which sets
  # user_data_replace_on_change = false plus lifecycle ignore_changes =
  # [user_data]. That stack protects instances inside a PREPAID capacity
  # block, where a surprise replacement burns bought hours. This fleet is
  # stateless, cheap, on-demand capacity, and the shard math (NODE_INDEX /
  # NODE_COUNT), the image, and every env var are all baked into user_data —
  # cloud-init runs ONCE, so the only way to deploy a change is a fresh boot.
  #
  # Do NOT add ignore_changes = [user_data]: it would turn an image update or
  # a NODE_COUNT correction into a silent no-op that quietly corrupts the
  # shard assignments on running nodes.
  #
  # Do NOT add create_before_destroy: during the overlap window two live
  # nodes would run the SAME NODE_INDEX and double-process (and double-write)
  # that shard.
  # ==========================================================================
  user_data_replace_on_change = true

  # The boot script does NOT create the log group (no awslogs-create-group):
  # the Terraform-managed group in iam.tf must exist before any node's
  # docker run references it, and user_data is opaque to the graph — so the
  # ordering must be stated explicitly.
  depends_on = [aws_cloudwatch_log_group.fleet]

  tags = merge(local.tags, { Name = "${local.name_prefix}-${count.index}" })
}
