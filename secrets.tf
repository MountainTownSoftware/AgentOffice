resource "aws_secretsmanager_secret" "opencode_office" {
  name        = "${var.project_name}-secrets"
  description = "Secrets for OpenCode Office (instance bootstrapping)"
}

resource "aws_secretsmanager_secret_version" "opencode_office" {
  secret_id = aws_secretsmanager_secret.opencode_office.id
  secret_string = jsonencode({
    openrouter_api_key  = var.openrouter_api_key
    discord_bot_token   = var.discord_bot_token
    gitea_admin_password = var.gitea_admin_password
  })
}