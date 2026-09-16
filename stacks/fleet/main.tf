provider "aws" {
  region = var.region
}

# Unlike the runtime stack, nothing here derives from a capacity reservation:
# the fleet is plain on-demand capacity, and its AZs come straight from
# var.subnet_azs (KTD9). Naming is deliberately fleet-specific (KTD10) so a
# fleet and a p5 runtime deployment in the same region never collide on
# region-unique names (key pair, SG, and later role/log-group names).
locals {
  name_prefix = "multi-scale-fleet"

  tags = merge(
    {
      Project   = "multi-scale"
      Stack     = "fleet"
      ManagedBy = "opentofu"
    },
    var.tags,
  )
}
