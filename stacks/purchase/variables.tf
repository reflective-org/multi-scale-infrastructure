variable "region" {
  description = "AWS region to search and purchase in. Capacity block availability differs by region AND instance type; see terraform.tfvars.example."
  type        = string
}

variable "instance_type" {
  description = "GPU instance type to reserve. Exactly p5.48xlarge or p5en.48xlarge (KTD2)."
  type        = string

  validation {
    condition     = contains(["p5.48xlarge", "p5en.48xlarge"], var.instance_type)
    error_message = "instance_type must be exactly \"p5.48xlarge\" or \"p5en.48xlarge\"."
  }
}

variable "instance_count" {
  description = "Number of instances in the capacity block (AWS allows 1-64 per block)."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 64 && floor(var.instance_count) == var.instance_count
    error_message = "instance_count must be a whole number between 1 and 64."
  }
}

variable "capacity_duration_hours" {
  description = "Duration of the capacity block in hours. Must be at least 24 and a multiple of 24."
  type        = number

  validation {
    condition     = var.capacity_duration_hours >= 24 && var.capacity_duration_hours % 24 == 0
    error_message = "capacity_duration_hours must be >= 24 and a multiple of 24 (whole days)."
  }
}

variable "start_date_range" {
  description = "Optional earliest start date for the block, RFC3339 (e.g. \"2026-09-01T00:00:00Z\")."
  type        = string
  default     = null
}

variable "end_date_range" {
  description = "Optional latest end date for the block, RFC3339 (e.g. \"2026-09-08T00:00:00Z\")."
  type        = string
  default     = null
}

variable "search_enabled" {
  description = "Gates the offering search. Leave true while searching and purchasing; set false after a completed purchase so drifted or empty lookups can never disturb the existing reservation."
  type        = bool
  default     = true
}

variable "capacity_block_offering_id" {
  description = "PURCHASE CONFIRMATION 1/2 — the reviewed offering ID from the search output. Setting this together with expected_upfront_fee spends real, non-refundable money on apply."
  type        = string
  default     = null

  validation {
    # Cross-variable (OpenTofu >= 1.9): a purchase requires explicit
    # confirmation of BOTH the reviewed offering and its exact fee (R2/R10).
    condition     = (var.capacity_block_offering_id == null) == (var.expected_upfront_fee == null)
    error_message = "capacity_block_offering_id and expected_upfront_fee must be set together (both or neither). A purchase requires confirming BOTH the reviewed offering ID and its exact upfront fee."
  }
}

variable "expected_upfront_fee" {
  description = "PURCHASE CONFIRMATION 2/2 — the exact upfront fee shown by the search output (string, e.g. \"28800.00\"). Verified against a fresh lookup before purchase."
  type        = string
  default     = null
}

variable "expected_availability_zone" {
  description = "Optional extra pin: the availability zone shown by the search output. When set, it is also verified against the fresh lookup before purchase."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the capacity block reservation."
  type        = map(string)
  default     = {}
}
