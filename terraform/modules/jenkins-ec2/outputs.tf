output "instance_id" {
  description = "Jenkins instance ID."
  value       = aws_instance.jenkins.id
}

output "public_ip" {
  description = "Jenkins public IP (changes after stop/start)."
  value       = aws_instance.jenkins.public_ip
}

output "jenkins_url" {
  description = "Jenkins URL."
  value       = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "security_group_id" {
  description = "Jenkins security group."
  value       = aws_security_group.jenkins.id
}
