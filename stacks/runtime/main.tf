provider "aws" {
  region = var.region
}

# The capacity reservation pins the availability zone for the whole stack
# (KTD4): capacity blocks are AZ-specific, so the AZ is derived here rather
# than asked for twice. Later units also consume instance type, state, and
# capacity from this lookup.
data "aws_ec2_capacity_block_reservation" "this" {
  id = var.capacity_reservation_id
}

locals {
  availability_zone = data.aws_ec2_capacity_block_reservation.this.availability_zone

  name_prefix = "multi-scale-gpu"

  tags = merge(
    {
      Project   = "multi-scale"
      Stack     = "runtime"
      ManagedBy = "opentofu"
    },
    var.tags,
  )
}
