output "next_steps" {
  description = "Cosa fare dopo."
  value       = <<-EOT
    Piattaforma installata. Ora:
      cd ../02-platform-config && terraform init && terraform apply
    Password iniziale di Argo CD:
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
  EOT
}
