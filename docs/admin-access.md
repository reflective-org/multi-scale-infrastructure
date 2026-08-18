# Admin access via EC2 Instance Connect

## Before you connect: does your IP need to be allowed?

How you connect determines what `admin_cidr_blocks` must contain:

- **CLI (`aws ec2-instance-connect ssh`)** — the SSH connection comes **from
  your own IP**, not from AWS. Your IP must be in `admin_cidr_blocks` or the
  connection will hang at the TCP level. Find it and set it before applying:

  ```bash
  curl -s ifconfig.me
  # e.g. 203.0.113.7
  ```

  ```hcl
  # stacks/runtime/terraform.tfvars
  admin_cidr_blocks = ["203.0.113.7/32"]
  ```

- **Browser console (EC2 → instance → Connect → EC2 Instance Connect)** — the
  connection originates from AWS's regional EC2 Instance Connect service
  ranges, which the security group always admits. No `admin_cidr_blocks`
  entry needed.

`admin_cidr_blocks` refuses `0.0.0.0/0` and `::/0` by design: never open SSH
to the world; use your own IP as a `/32`.

## Connecting

### One-liner (recommended)

```bash
aws ec2-instance-connect ssh --instance-id i-0123456789abcdef0 --os-user ec2-user
```

This generates an ephemeral key, pushes the public half to the instance, and
opens the SSH session in one step.

### Manual flow

Push a public key, then SSH **within 60 seconds** (the pushed key expires):

```bash
aws ec2-instance-connect send-ssh-public-key \
  --instance-id i-0123456789abcdef0 \
  --instance-os-user ec2-user \
  --ssh-public-key file://~/.ssh/multi-scale-gpu.pub

ssh -i ~/.ssh/multi-scale-gpu ec2-user@<instance-public-dns>
```

## Sample admin IAM policy

Grant admins the ability to push SSH keys to this stack's instances as
`ec2-user` only. Replace the region and account ID; `ec2:DescribeInstances`
cannot be resource-scoped, so it stays on `*`.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SendSSHPublicKeyAsEc2User",
      "Effect": "Allow",
      "Action": "ec2-instance-connect:SendSSHPublicKey",
      "Resource": "arn:aws:ec2:us-east-1:123456789012:instance/*",
      "Condition": {
        "StringEquals": {
          "ec2:osuser": "ec2-user"
        }
      }
    },
    {
      "Sid": "DescribeInstancesForConnect",
      "Effect": "Allow",
      "Action": "ec2:DescribeInstances",
      "Resource": "*"
    }
  ]
}
```

## Notes

- Pushed keys are valid for **60 seconds**; after that, push again. There is
  nothing to clean up — expiry is automatic.
- Every `SendSSHPublicKey` call is **logged in CloudTrail**, giving a per-admin
  audit trail of who connected where and when.
- The key pair registered by the runtime stack (`public_key` /
  `existing_key_pair_name`) is the **break-glass path**: plain
  `ssh -i <private-key> ec2-user@<public-dns>` works from any CIDR in
  `admin_cidr_blocks`, independent of EC2 Instance Connect and IAM.
