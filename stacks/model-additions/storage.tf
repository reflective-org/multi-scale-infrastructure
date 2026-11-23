# The data volume holds /srv/model-additions: each addition's state file and
# working folder. It is separate from the instance so that it survives an
# instance replacement (a new AMI, a new instance type).
#
# `tofu destroy` deletes it, and with it every open addition's state.

resource "aws_ebs_volume" "data" {
  availability_zone = local.availability_zone
  size              = var.data_volume_size_gib
  type              = "gp3"
  encrypted         = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-data" })
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.host.id

  # Detach on a stopped instance is safe; when the instance is being
  # replaced, let AWS detach the volume rather than failing the apply.
  stop_instance_before_detaching = true
}
