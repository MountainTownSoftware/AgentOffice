variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "availability_zone" {
  description = <<-EOT
    AWS availability zone for the subnet. Empty means "derive it from
    aws_region" (e.g. us-east-2 -> us-east-2a), which keeps the AZ in sync
    with the region instead of silently failing on a mismatch.
  EOT
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "opencode-office"
}

variable "instance_type" {
  description = "EC2 instance type (t2.micro is free tier eligible)"
  type        = string
  default     = "t2.micro"
}

variable "key_name" {
  description = "Name of the SSH key pair"
  type        = string
  default     = "opencode-office"
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file"
  type        = string
  default     = "~/.ssh/agent-office.pub"
}

variable "gitea_version" {
  description = "Gitea version to install"
  type        = string
  default     = "1.23.6"
}

variable "gitea_admin_password" {
  description = "Gitea admin user password (also used by the Gitea Terraform provider)"
  type        = string
  sensitive   = true
}

variable "bootstrap_wait" {
  description = "Seconds to wait for Gitea bootstrap before provisioning repos"
  type        = string
  default     = "120s"
}

variable "openrouter_api_key" {
  description = "OpenRouter API key for AI model access"
  type        = string
  sensitive   = true
}

variable "discord_bot_token" {
  description = "Discord bot token for the Product Manager agent"
  type        = string
  sensitive   = true
  default     = ""
}

# --- VPC / Networking ---

variable "vpc_name" {
  description = "Name for the VPC. Use different names to deploy isolated AgentOffice instances in separate VPCs."
  type        = string
  default     = "agentoffice"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

# --- Domain ---

variable "domain_name" {
  description = "Domain name for HTTPS (optional). Requires DNS A record pointed to the instance IP."
  type        = string
  default     = ""
}

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt notifications (required if domain_name is set)"
  type        = string
  default     = ""
}

variable "source_repo_url" {
  description = "Public git URL of this project (e.g. GitHub). If set, the bootstrap clones and pushes these tofu files into the AgentOffice - Tofu Gitea repo."
  type        = string
  default     = ""
}
variable "agent_models" {
  description = "Models per agent role"
  type        = map(string)
  default = {
    architect        = "openrouter/deepseek/deepseek-v4-pro"
    staff_tech_lead  = "openrouter/deepseek/deepseek-v4-pro"
    senior_developer = "openrouter/deepseek/deepseek-v4-pro"
    junior_developer = "openrouter/deepseek/deepseek-v4-pro"
    product_manager  = "openrouter/deepseek/deepseek-v4-pro"
    sdet             = "openrouter/deepseek/deepseek-v4-pro"
  }
}

variable "atlantis_version" {
  description = "Atlantis version to install"
  type        = string
  default     = "0.33.0"
}

variable "tofu_version" {
  description = "OpenTofu version to install"
  type        = string
  default     = "1.9.0"
}