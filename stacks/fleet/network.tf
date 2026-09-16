# Self-contained minimal network: one VPC, one public subnet PER availability
# zone in var.subnet_azs (R2, KTD9), an internet gateway, and a default route
# out. Divergence from the runtime stack: that stack pins a single subnet to
# the capacity reservation's AZ; the fleet has no reservation, so the operator
# steers AZ placement via subnet_azs and instances (a later unit) spread with
# element(subnet_ids, count.index).

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = local.name_prefix })
}

resource "aws_subnet" "public" {
  count = length(var.subnet_azs)

  vpc_id = aws_vpc.this.id
  # Consecutive /20s of the default /16; adapts to a smaller vpc_cidr if
  # supplied (up to 16 AZs before the /16 is exhausted).
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = "${var.region}${var.subnet_azs[count.index]}"
  map_public_ip_on_launch = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-public-${var.subnet_azs[count.index]}" })
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
  count = length(var.subnet_azs)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
