terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.53.0, < 7.0.0"
    }
  }

  # Remote state in S3, with S3-native locking (use_lockfile; no DynamoDB table).
  # The bucket and its region aren't committed: copy backend.hcl.example to
  # backend.hcl (git-ignored), fill them in, and run
  # `tofu init -backend-config=backend.hcl`. Never commit state.
  backend "s3" {
    key          = "multi-scale/model-additions/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
