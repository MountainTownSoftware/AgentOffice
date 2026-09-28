# Gitea provider — configured against the instance we just deployed.
provider "gitea" {
  base_url = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_eip.office.public_ip}"
  username = "admin"
  password = var.gitea_admin_password
}

# Wait for the instance to finish bootstrapping Gitea before provisioning repos.
resource "time_sleep" "wait_for_gitea" {
  depends_on      = [aws_instance.office]
  create_duration = var.bootstrap_wait
  triggers = {
    instance_id = aws_instance.office.id
  }
}

# Self-hosting: the tofu files managing this instance live in Gitea.
resource "gitea_repository" "agent_office_tofu" {
  depends_on         = [time_sleep.wait_for_gitea]
  username           = "admin"
  name               = "agent-office-tofu"
  description        = "AgentOffice infrastructure — bootstrap OpenTofu files"
  private            = true
  auto_init          = true
  default_branch     = "main"
  has_issues         = true
  has_pull_requests  = true
}