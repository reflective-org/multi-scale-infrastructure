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
  #   key          = "multi-scale/runtime/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }

  # Optional: OpenTofu client-side state encryption (defense in depth for the
  # no-secrets-in-state posture; see README "State storage").
  #
  # encryption {
  #   key_provider "aws_kms" "state" {
  #     kms_key_id = "alias/YOUR-tofu-state-key"
  #     region     = "us-east-1"
  #     key_spec   = "AES_256"
  #   }
  #   method "aes_gcm" "state" {
  #     keys = key_provider.aws_kms.state
  #   }
  #   state {
  #     method = method.aes_gcm.state
  #   }
  #   plan {
  #     method = method.aes_gcm.state
  #   }
  # }
}
