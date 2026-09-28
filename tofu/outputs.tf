output "instance_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_eip.office.public_ip
}

output "instance_public_dns" {
  description = "Public DNS of the EC2 instance"
  value       = aws_instance.office.public_dns
}

output "gitea_url" {
  description = "Gitea web interface URL"
  value       = var.domain_name != "" ? "https://${var.domain_name}" : "http://${aws_eip.office.public_ip}"
}

output "ssh_command" {
  description = "SSH connect command"
  value       = "ssh -i ~/.ssh/opencode_office ubuntu@${aws_eip.office.public_ip}"
}

output "gitea_admin_password" {
  description = "Gitea admin password (generated on first boot)"
  value       = "Retrieved from instance: cat /home/ubuntu/.gitea_admin_password"
}