module "network" {
  source = "./modules/network"

  vpc_cidr             = "10.20.0.0/16"
  public_subnet_1_cidr = "10.20.1.0/24"
  public_subnet_2_cidr = "10.20.2.0/24"

  common_tags = local.common_tags
}
resource "aws_security_group" "ec2_sg" {
  name        = "ec2-security-group"
  description = "Allow SSH"
  vpc_id      = module.network.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.common_tags,
    {
      Name = "ec2-sg"
    }
  )
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_instance" "running_instance" {
  ami                    = "ami-12345678"
  instance_type          = "t3.micro"
  subnet_id              = module.network.public_subnet_1_id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  tags = merge(
    local.common_tags,
    {
      Name        = "running-instance"
      Owner       = "devops"
      Environment = "dev"
    }
  )
}
resource "aws_instance" "stopped_instance" {
  ami                    = "ami-87654321"
  instance_type          = "t3.micro"
  subnet_id              = module.network.public_subnet_2_id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]

  tags = merge(
    local.common_tags,
    {
      Name        = "stopped-instance"
      Environment = "dev"
      Owner       =  "devops"
    }
  )
}
resource "aws_ebs_volume" "unused_volume" {
  availability_zone = "us-east-1a"
  size              = 8

  tags = merge(
    local.common_tags,
    {
      Name = "unused-volume"
    }
  )
}
resource "aws_s3_bucket" "logs_bucket" {
  bucket = "cost-hygiene-logs"

  tags = merge(
    local.common_tags,
    {
      Name = "logs-bucket"
    }
  )
}
resource "aws_s3_bucket_versioning" "logs_versioning" {
  bucket = aws_s3_bucket.logs_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_lifecycle_configuration" "logs_lifecycle" {
  count  = var.enable_s3_lifecycle ? 1 : 0
  bucket = aws_s3_bucket.logs_bucket.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}