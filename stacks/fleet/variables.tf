# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region to run the fleet in. Check g6e availability first — see docs/runbooks.md."
  type        = string
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the stack's self-contained VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_azs" {
  description = "Availability zone SUFFIXES (e.g. [\"a\", \"b\"]) appended to var.region; one public subnet is created per entry and instances spread across them round-robin (R2, KTD9). Steer this list when an AZ lacks g6e capacity — see docs/runbooks.md."
  type        = list(string)
  default     = ["a", "b"]

  validation {
    condition     = length(var.subnet_azs) > 0
    error_message = "subnet_azs must list at least one AZ suffix (e.g. [\"a\", \"b\"]) — the fleet needs a subnet to launch into."
  }
}

# ---------------------------------------------------------------------------
# Admin access
# ---------------------------------------------------------------------------

variable "admin_cidr_blocks" {
  description = "Admin source CIDRs allowed to SSH. Required for CLI-initiated `aws ec2-instance-connect ssh` (it connects from your own IP) and for plain ssh; browser-console EC2 Instance Connect needs no entry here. IPv4 only. See docs/admin-access.md."
  type        = list(string)
  default     = []

  # IPv4 shape check on top of CIDR validity: the SSH rules are cidr_ipv4,
  # so an IPv6 entry that slipped past cidrhost() would only fail later,
  # inside the provider.
  validation {
    condition = alltrue([
      for c in var.admin_cidr_blocks :
      can(cidrhost(c, 0)) && can(regex("^(\\d{1,3}\\.){3}\\d{1,3}/\\d{1,2}$", c))
    ])
    error_message = "Every admin_cidr_blocks entry must be a valid IPv4 CIDR, e.g. \"203.0.113.7/32\"."
  }

  validation {
    condition     = !contains(var.admin_cidr_blocks, "0.0.0.0/0") && !contains(var.admin_cidr_blocks, "::/0")
    error_message = "admin_cidr_blocks must not open SSH to the world (0.0.0.0/0 or ::/0). Use your own IP as a /32 — see docs/admin-access.md."
  }
}

variable "existing_key_pair_name" {
  description = "Name of an EC2 key pair that already exists in this region. Set exactly one of existing_key_pair_name or public_key."
  type        = string
  default     = null
}

variable "public_key" {
  description = "SSH public key material (contents of the .pub file, e.g. from scripts/generate-key.sh) to register as a new key pair. Set exactly one of existing_key_pair_name or public_key."
  type        = string
  default     = null

  validation {
    condition     = (var.public_key == null) != (var.existing_key_pair_name == null)
    error_message = "Set exactly one of public_key or existing_key_pair_name: pass a public key (scripts/generate-key.sh prints one) to register a new key pair, or name an existing key pair to reuse it."
  }
}

variable "key_pair_name" {
  description = "Name PREFIX for the key pair registered from public_key (a random suffix is appended so region-unique key names never collide — KTD10). Ignored when existing_key_pair_name is set."
  type        = string
  default     = "multi-scale-fleet"
}

# ---------------------------------------------------------------------------
# Workload: image and data plane
# ---------------------------------------------------------------------------

variable "docker_image" {
  description = "Container image every node runs. A private-ECR URI (matching <account>.dkr.ecr.<region>.amazonaws.com/...) is detected by shape (KTD7): it gets automatic ECR login at boot and a pull policy scoped to exactly that repository, with the registry region parsed from the URI itself — not from var.region, so cross-region pulls work. Any other registry (ghcr.io, public.ecr.aws, docker.io, ...) gets no ECR grant. Digest-pinned URIs (...@sha256:<digest>) are recommended so partial replacements never run a version-heterogeneous fleet — see docs/runbooks.md."
  type        = string

  validation {
    condition     = length(trimspace(var.docker_image)) > 0
    error_message = "docker_image is required: name the image the fleet runs (a private ECR URI or any public registry reference, e.g. \"ghcr.io/org/train:v3\")."
  }
}

variable "s3_bucket" {
  description = "Bare name of the operator-supplied S3 bucket the containers use (e.g. \"my-training-data\" — not an s3:// URI). The instance role may read the whole bucket but write only under s3_output_prefix. The bucket itself is not managed by this stack."
  type        = string

  validation {
    condition     = can(regex("^[^/:]+$", var.s3_bucket))
    error_message = "s3_bucket must be a bare bucket name (e.g. \"my-training-data\"), not an s3:// URI or a path — the stack builds the ARNs itself."
  }
}

variable "s3_output_prefix" {
  description = "Key prefix under s3_bucket where the containers may write: PutObject and the multipart-upload actions are granted ONLY under <s3_bucket>/<s3_output_prefix>/*. Input data must live OUTSIDE this prefix — every fleet node can write (and overwrite) objects under it, so inputs stored here lose their read-only guarantee. No leading or trailing slash; nested prefixes like \"runs/2026-09\" are fine."
  type        = string
  default     = "outputs"

  # The write ARN is built as <bucket>/<prefix>/*: a leading slash or empty
  # prefix would silently widen (or break) the grant, a trailing slash would
  # double the separator — reject all three at the variable boundary.
  validation {
    condition     = length(var.s3_output_prefix) > 0 && !startswith(var.s3_output_prefix, "/") && !endswith(var.s3_output_prefix, "/")
    error_message = "s3_output_prefix must be a non-empty key prefix without leading or trailing slashes (e.g. \"outputs\" or \"runs/2026-09\") — the stack adds the slashes when it builds the policy ARN."
  }
}

variable "enable_container_logs" {
  description = "Ship container stdout/stderr to CloudWatch Logs via Docker's awslogs driver (R8, default on). Grants the instance role the three logs: write actions scoped to the fleet log group; disabling removes that grant (and, in the boot script, the awslogs flags)."
  type        = bool
  default     = true
}
