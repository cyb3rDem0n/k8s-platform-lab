variable "kubeconfig_path" {
  description = "Percorso del kubeconfig del cluster (scaricato da Ansible)."
  type        = string
  default     = "~/.kube/config-nuc"
}

variable "kube_context" {
  description = "Contesto del kubeconfig da usare. null = contesto corrente."
  type        = string
  default     = null
}

variable "base_domain" {
  description = "Dominio interno del laboratorio. home.arpa è riservato alle reti domestiche (RFC 8375)."
  type        = string
  default     = "lab.home.arpa"
}

# ---- Versioni: TUTTE bloccate. Aggiornale con scripts/check-versions.sh e un commit dedicato. ----

variable "versions" {
  description = "Versioni dei componenti di piattaforma."
  type = object({
    gateway_api            = string
    local_path_provisioner = string
    metrics_server_chart   = string
    metallb_chart          = string
    cert_manager_chart     = string
    ngf_chart              = string
    argocd_chart           = string
  })
  default = {
    gateway_api            = "v1.4.1"
    local_path_provisioner = "v0.0.31"
    metrics_server_chart   = "3.12.2"
    metallb_chart          = "0.15.2"
    cert_manager_chart     = "v1.18.2"
    ngf_chart              = "2.6.0"
    argocd_chart           = "9.5.4"
  }
}
