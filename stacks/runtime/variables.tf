# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

variable "region" {
  description = "AWS region. Must be the region the capacity block was purchased in."
  type        = string
}

variable "capacity_reservation_id" {
  description = "Capacity block reservation ID (cr-...) to launch into, from the purchase stack's output or a previously purchased block."
  type        = string

  validation {
    condition     = can(regex("^cr-", var.capacity_reservation_id))
    error_message = "capacity_reservation_id must be a capacity reservation ID starting with \"cr-\"."
  }
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

# ---------------------------------------------------------------------------
# Admin access
# ---------------------------------------------------------------------------

variable "admin_cidr_blocks" {
  description = "Admin source CIDRs allowed to SSH. Required for CLI-initiated `aws ec2-instance-connect ssh` (it connects from your own IP) and for plain ssh; browser-console EC2 Instance Connect needs no entry here. See docs/admin-access.md."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.admin_cidr_blocks : can(cidrhost(c, 0))])
    error_message = "Every admin_cidr_blocks entry must be a valid CIDR, e.g. \"203.0.113.7/32\"."
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
  description = "Name for the key pair registered from public_key. Ignored when existing_key_pair_name is set."
  type        = string
  default     = "multi-scale-gpu"
}

# ---------------------------------------------------------------------------
# Instances
# ---------------------------------------------------------------------------

variable "launch_instance" {
  description = "Whether to launch instances into the capacity block. Set false to pre-provision networking (and later FSx) before the block's start time — pre-loading training data is a feature, see docs/runbooks.md."
  type        = bool
  default     = true
}

variable "instance_count" {
  description = "Number of instances to launch into the capacity block. Must not exceed the reservation's available capacity."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count == floor(var.instance_count) && var.instance_count >= 1 && var.instance_count <= 64
    error_message = "instance_count must be a whole number between 1 and 64 (a capacity block holds at most 64 instances)."
  }
}

variable "ami_flavor" {
  description = "Deep Learning Base OSS NVIDIA Driver AMI generation: \"al2\" (Amazon Linux 2, the R4 default — frozen since June 2026, no security patches) or \"al2023\" (the patched alternative). Ignored when ami_id is set."
  type        = string
  default     = "al2"

  validation {
    condition     = contains(["al2", "al2023"], var.ami_flavor)
    error_message = "ami_flavor must be \"al2\" or \"al2023\"."
  }
}

variable "ami_id" {
  description = "Explicit AMI ID to run instead of the SSM-resolved Deep Learning AMI. Setting this bypasses SSM resolution (and ami_flavor) entirely."
  type        = string
  default     = null

  validation {
    condition     = var.ami_id == null || can(regex("^ami-", var.ami_id))
    error_message = "ami_id must be an AMI ID starting with \"ami-\"."
  }
}

variable "root_volume_size_gib" {
  description = "Root (gp3) volume size in GiB. The Deep Learning AMI needs headroom, hence the 100 GiB floor. The root volume is destroyed with the instance when the block ends — only /data survives."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size_gib >= 100
    error_message = "root_volume_size_gib must be at least 100 GiB — the Deep Learning AMI needs the headroom."
  }
}

# FSx variables are appended by U5.
