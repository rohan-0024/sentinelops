output "lab_mode" {
  description = "Whether AWS Academy lab mode is active."
  value       = var.lab_mode
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "kubeconfig_command" {
  description = "Run this to configure kubectl."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  description = "Push images here."
  value       = module.ecr.repository_url
}

output "jenkins_url" {
  description = "Jenkins URL (empty if the host is disabled)."
  value       = var.create_jenkins_ec2 ? module.jenkins[0].jenkins_url : ""
}

output "jenkins_public_ip" {
  description = "Jenkins host IP for the Ansible inventory."
  value       = var.create_jenkins_ec2 ? module.jenkins[0].public_ip : ""
}

output "app_irsa_role_arn" {
  description = "IRSA role for the app service account (empty in lab mode)."
  value       = module.eks.app_irsa_role_arn
}

output "finops_lambda" {
  description = "FinOps autopilot Lambda name."
  value       = module.finops.lambda_name
}

output "finops_override_parameter" {
  description = "aws ssm put-parameter --overwrite --name <this> --value keep-alive  to skip tonight's teardown."
  value       = module.finops.override_parameter
}
