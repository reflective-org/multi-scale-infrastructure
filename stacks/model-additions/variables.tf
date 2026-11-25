# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = "AZ for the instance and its data volume. Defaults to the region's first available AZ. Changing it later replaces both, losing the data volume's contents."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags merged onto every resource."
  type        = map(string)
  default     = {}
}

variable "environment" {
  description = "Value of the Environment tag on every resource."
  type        = string
  default     = "production"
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the stack's self-contained VPC."
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block, e.g. \"10.20.0.0/16\"."
  }
}

# ---------------------------------------------------------------------------
# Instance
# ---------------------------------------------------------------------------

variable "running" {
  description = "true starts the host, false stops it. On while an addition is open, off between additions (docs/model-additions.md)."
  type        = bool
  default     = true
}

variable "instance_type" {
  description = "EC2 instance type. CPU only: the models run in float64 on CPU, and the host runs untrusted model code that has no use for a GPU."
  type        = string
  default     = "m7i.2xlarge"

  validation {
    condition     = !can(regex("^(p|g|trn|inf|dl)[0-9]", var.instance_type))
    error_message = "instance_type must be a CPU instance; GPU and accelerator families (p, g, trn, inf, dl) are not for this host."
  }
}

variable "ami_id" {
  description = "Explicit AMI ID. Leave null to use Canonical's current Ubuntu 24.04 (amd64) image via SSM."
  type        = string
  default     = null
}

variable "root_volume_size_gib" {
  description = "Root volume size in GiB (OS, Docker images and build cache)."
  type        = number
  default     = 60

  validation {
    condition     = var.root_volume_size_gib >= 30
    error_message = "root_volume_size_gib must be at least 30: Docker images and the build cache live on the root volume."
  }
}

variable "data_volume_size_gib" {
  description = "Data volume size in GiB, mounted at /srv/model-additions (one folder per addition)."
  type        = number
  default     = 200

  validation {
    condition     = var.data_volume_size_gib >= 50
    error_message = "data_volume_size_gib must be at least 50."
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions runner software (installed at first boot, registered later)
# ---------------------------------------------------------------------------

variable "runner_version" {
  description = "actions/runner release to install, without the leading v."
  type        = string
  default     = "2.338.2"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.runner_version))
    error_message = "runner_version must look like 2.338.2 (no leading v)."
  }
}

variable "runner_sha256" {
  description = "SHA-256 of actions-runner-linux-x64-<runner_version>.tar.gz, from the release's asset digest. Change it together with runner_version."
  type        = string
  default     = "baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.runner_sha256))
    error_message = "runner_sha256 must be 64 lowercase hex characters."
  }
}
