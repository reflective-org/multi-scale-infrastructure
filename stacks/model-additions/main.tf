# Host for the aerosol model-addition automation (the self-hosted GitHub Actions
# runners described in the comparison repository's docs/automation/RUNBOOK.md).
#
# Self-contained: no dependency on any other stack's state. CPU only — the
# models run in float64 on CPU. The machine is switched on for an addition and
# off between additions (var.running); its working folders live on a separate
# data volume that survives stopping, and replacing, the instance.

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # The instance and its data volume must share an AZ; pin it once.
  availability_zone = coalesce(var.availability_zone, data.aws_availability_zones.available.names[0])

  name_prefix = "model-additions"

  tags = merge(
    {
      Project   = "model-additions"
      Stack     = "model-additions"
      ManagedBy = "opentofu"
    },
    var.tags,
  )
}
