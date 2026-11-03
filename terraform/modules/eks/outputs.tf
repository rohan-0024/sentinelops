output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca" {
  description = "Base64 cluster CA certificate."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "node_group_name" {
  description = "Default node group name (used by FinOps autopilot)."
  value       = aws_eks_node_group.default.node_group_name
}

output "oidc_issuer" {
  description = "OIDC issuer URL."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "app_irsa_role_arn" {
  description = "App IRSA role ARN (empty in lab mode)."
  value       = var.enable_irsa ? aws_iam_role.app_irsa[0].arn : ""
}
