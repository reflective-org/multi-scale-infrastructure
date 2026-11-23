terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.53.0, < 7.0.0"
    }
  }

  # Remote state (recommended). Uncomment and point at your own bucket.
  # OpenTofu >= 1.10 supports S3-native locking (use_lockfile) — no DynamoDB
  # table required. Never commit state; this repo's .gitignore excludes it.
  #
  # backend "s3" {
  #   bucket       = "YOUR-tofu-state-bucket"
  #   key          = "multi-scale/model-additions/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}
