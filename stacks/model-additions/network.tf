# Minimal self-contained network: one VPC, one public subnet, an internet
# gateway and a default route out. The instance needs outbound access only
# (GitHub, Slack, the Anthropic API, package mirrors); a public IP is cheaper
# than a NAT gateway, and the security group admits nothing inbound.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = local.name_prefix })
}

# A public IP with no inbound rules (security.tf) instead of a NAT gateway,
# which would cost more than the instance while it is mostly stopped.
#trivy:ignore:AVD-AWS-0164
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, 0)
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-public" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, { Name = local.name_prefix })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-public" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
