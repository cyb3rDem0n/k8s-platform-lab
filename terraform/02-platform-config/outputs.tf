output "hosts_entries" {
  description = "Righe da aggiungere a /etc/hosts (o al DNS del router) usando l'IP del Gateway."
  value       = <<-EOT
    IP del Gateway:  kubectl -n nginx-gateway get gateway lab-gateway -o jsonpath='{.status.addresses[0].value}'
    Poi in /etc/hosts:
      <IP>  hello.${var.base_domain} argocd.${var.base_domain}
    Certificato della CA da importare nel browser/sistema:
      kubectl -n cert-manager get secret lab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-root-ca.crt
  EOT
}
