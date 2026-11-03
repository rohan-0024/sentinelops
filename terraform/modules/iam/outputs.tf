output "eks_cluster_role_arn" {
  description = "EKS cluster role ARN."
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_node_role_arn" {
  description = "EKS node role ARN."
  value       = aws_iam_role.eks_node.arn
}

output "jenkins_role_arn" {
  description = "Jenkins EC2 role ARN."
  value       = aws_iam_role.jenkins.arn
}

output "jenkins_instance_profile_name" {
  description = "Jenkins EC2 instance profile name."
  value       = aws_iam_instance_profile.jenkins.name
}

output "finops_lambda_role_arn" {
  description = "FinOps Lambda execution role ARN."
  value       = aws_iam_role.finops.arn
}
