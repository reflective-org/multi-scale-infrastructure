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

# Instance and FSx variables are appended by later units.
