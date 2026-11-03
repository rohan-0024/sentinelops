# VPC with 2 public + 2 private subnets across 2 AZs, a single NAT gateway
# (cost-optimised), default SG locked down, and flow logs to S3.

# AZs are pinned explicitly (deterministic plans; EKS does not support every AZ, e.g. us-east-1e).
locals {
  azs = slice(var.azs, 0, var.az_count)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-vpc" }
}

# Locks down the default SG (no rules = deny all) so nothing uses it by accident.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-default-deny" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.cidr_block, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name                                        = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.cidr_block, 4, count.index + 8)
  availability_zone = local.azs[count.index]
  tags = {
    Name                                        = "${var.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_eip" "nat" {
  # checkov:skip=CKV2_AWS_19:This EIP is attached to the NAT gateway, not an instance (false positive)
  count  = var.enable_nat_gateway ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.name}-nat" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  dynamic "route" {
    for_each = var.enable_nat_gateway ? [1] : []
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.this[0].id
    }
  }
  tags = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = var.az_count
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---- Flow logs -> S3 (no IAM role needed, works in AWS Academy) ----
resource "aws_s3_bucket" "flow_logs" {
  # checkov:skip=CKV_AWS_144:Cross-region replication out of scope for flow logs
  # checkov:skip=CKV2_AWS_62:No consumers for flow-log object events
  # checkov:skip=CKV_AWS_18:This bucket is itself a log sink; logging it would recurse
  # checkov:skip=CKV_AWS_21:Flow logs are append-only and expire after retention; versioning adds cost only
  bucket_prefix = "${var.name}-flowlogs-"
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "flow_logs" {
  bucket                  = aws_s3_bucket.flow_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs" {
  bucket = aws_s3_bucket.flow_logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.flow_log_retention_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_flow_log" "this" {
  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.flow_logs.arn
  tags                 = { Name = "${var.name}-flow-log" }
}
