terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    gitea = {
      source  = "Lerentis/gitea"
      version = ">= 0.16.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# SSH key pair - create before apply: ssh-keygen -t ed25519 -f opencode-office
resource "aws_key_pair" "office" {
  key_name   = var.key_name
  public_key = file(var.ssh_public_key_path)
}

# Security group
resource "aws_security_group" "office" {
  name        = "${var.project_name}-sg"
  description = "Security group for OpenCode Office"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP (nginx)"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS (nginx)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = var.project_name
  }
}

# EC2 instance
resource "aws_instance" "office" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.office.key_name
  vpc_security_group_ids = [aws_security_group.office.id]
  iam_instance_profile   = aws_iam_instance_profile.opencode_office.name
  user_data_base64 = base64gzip(templatefile("${path.module}/user_data.sh.tpl", {
    gitea_version     = var.gitea_version
    domain_name       = var.domain_name
    letsencrypt_email = var.letsencrypt_email
    agent_models      = var.agent_models
    project_name      = var.project_name
    aws_region        = var.aws_region
    source_repo_url   = var.source_repo_url
  }))
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.project_name}-instance"
    Project = var.project_name
  }
}

# Elastic IP
resource "aws_eip" "office" {
  instance = aws_instance.office.id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-eip"
    Project = var.project_name
  }
}