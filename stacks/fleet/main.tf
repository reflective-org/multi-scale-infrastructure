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

# ECR detection is a pure URI-shape rule (KTD7): an image hosted on
# <account>.dkr.ecr.<region>.amazonaws.com is private ECR — the pull policy
# targets the repository ARN derived here, and the boot script (later unit)
# logs into the CAPTURED region, not var.region, so cross-region pulls work.
# public.ecr.aws and every other registry get no ECR grant and no login.
# Cross-account pulls stay out of scope (they need a far-side repo policy).
locals {
  # Anchored at the registry-host position: account id is the host's first
  # label, region the ecr label. Captures: [account, region, path-and-ref].
  ecr_registry_regex = "^([0-9]+)\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com/(.+)$"

  is_ecr = can(regex(local.ecr_registry_regex, var.docker_image))

  ecr_parts   = local.is_ecr ? regex(local.ecr_registry_regex, var.docker_image) : ["", "", ""]
  ecr_account = local.ecr_parts[0]
  ecr_region  = local.ecr_parts[1]

  # Repository path = everything after the host's first "/", stripped of the
  # trailing ref. Two ref shapes exist and both must parse (the runbook
  # recommends digest pinning, so "@" is the primary case, not an edge):
  #   1. digest pin  org/train@sha256:<digest> — "@" is never valid inside a
  #      repository path, so everything from the first "@" is the ref;
  #   2. tag         team/train:v3 — a ":" is a tag separator only when it
  #      appears AFTER the final "/" (nested repos keep their slashes).
  ecr_path_no_digest = split("@", local.ecr_parts[2])[0]
  ecr_repository     = replace(local.ecr_path_no_digest, "/:[^/]*$/", "")

  ecr_repository_arn = local.is_ecr ? "arn:aws:ecr:${local.ecr_region}:${local.ecr_account}:repository/${local.ecr_repository}" : null
}

# Fleet log-group name (KTD10 fleet-prefixed): iam.tf scopes the logs: grant
# to it now; the boot script's awslogs flags (later unit) reuse it.
locals {
  log_group_name = "/${local.name_prefix}/containers"
}
