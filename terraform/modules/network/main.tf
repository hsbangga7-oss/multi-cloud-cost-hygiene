resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr

  tags = merge(
    var.common_tags,
    {
      Name = "cost-hygiene-vpc"
    }
  )
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_1_cidr
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = merge(
    var.common_tags,
    {
      Name = "public-subnet-1"
    }
  )
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_2_cidr
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true

  tags = merge(
    var.common_tags,
    {
      Name = "public-subnet-2"
    }
  )
}
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(
    var.common_tags,
    {
      Name = "cost-hygiene-igw"
    }
  )
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(
    var.common_tags,
    {
      Name = "public-route-table"
    }
  )
}
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}