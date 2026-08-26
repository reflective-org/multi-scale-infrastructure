# Self-contained minimal network (R9): one VPC, one public subnet in the
# reservation's AZ, an internet gateway, and a default route out.

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = local.name_prefix })
}

resource "aws_subnet" "public" {
  vpc_id = aws_vpc.this.id
  # First /20 of the default /16; adapts to a smaller vpc_cidr if supplied.
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
