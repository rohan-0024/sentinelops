# Jenkins + SonarQube host (configured afterwards by Ansible).
# Ubuntu 22.04, IMDSv2, encrypted gp3 root, SG open only to the admin CIDR,
# tagged Schedule=office-hours so the FinOps autopilot can stop it.

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "jenkins" {
  # checkov:skip=CKV_AWS_24:SSH source is var.admin_cidrs, whose validation rejects 0.0.0.0/0; checkov cannot evaluate it
  name        = "${var.name}-jenkins"
  description = "Jenkins/SonarQube host - admin access only"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from admin CIDR (Ansible)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }
  ingress {
    description = "Jenkins UI from admin CIDR"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }
  ingress {
    description = "SonarQube UI from admin CIDR"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = var.admin_cidrs
  }
  egress {
    description = "HTTPS out (GitHub, ECR, EKS API, package mirrors)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "HTTP out (apt mirrors)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "jenkins" {
  # checkov:skip=CKV_AWS_88:Public IP is needed for the Jenkins UI and Ansible over SSH; ingress is limited to admin_cidrs
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.jenkins.id]
  associate_public_ip_address = true
  iam_instance_profile        = var.instance_profile_name
  key_name                    = var.key_name
  monitoring                  = true
  ebs_optimized               = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size           = var.disk_gb
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
  }

  # Minimal bootstrap; everything else is Ansible (roles: docker, jenkins, sonarqube, trivy, node-exporter, hardening).
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    apt-get update -y
    apt-get install -y python3 python3-apt
    sysctl -w vm.max_map_count=524288
  EOT

  tags = {
    Name     = "${var.name}-jenkins"
    Schedule = "office-hours"
    Role     = "ci"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
