variable "kubeconfig_path" {
  type    = string
  default = "~/.kube/config-nuc"
}

variable "kube_context" {
  type    = string
  default = null
}

variable "base_domain" {
  type    = string
  default = "lab.home.arpa"
}

variable "metallb_address_range" {
  description = <<-EOT
    Intervallo di IP della TUA LAN che MetalLB può assegnare ai Service LoadBalancer.
    Deve stare FUORI dal range DHCP del router, altrimenti avrai conflitti di indirizzo.
  EOT
  type        = string
  default     = "192.168.1.240-192.168.1.249"
}

variable "enable_gitops" {
  description = "Crea AppProject e root Application di Argo CD (capitolo 10). false nei capitoli precedenti."
  type        = bool
  default     = false
}

variable "gitops_repo_url" {
  description = "URL HTTPS del TUO repository Git (fork di questo)."
  type        = string
  default     = "https://github.com/cyb3rdem0n/k8s-platform-lab.git"
}

variable "gitops_revision" {
  description = "Branch, tag o commit che Argo CD segue."
  type        = string
  default     = "main"
}
