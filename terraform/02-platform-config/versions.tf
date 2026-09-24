terraform {
  required_version = ">= 1.9"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0" # la 3.x ha cambiato sintassi: `kubernetes = { ... }` e `set = [ ... ]`
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0" # 3.x: rimosse le risorse deprecate senza suffisso _v1
    }
  }

  # Stato LOCALE: va bene per un laboratorio a singolo operatore.
  # Nella parte cloud lo sposteremo su un backend remoto con locking (S3, GCS, Azure Storage).
  backend "local" {
    path = "terraform.tfstate"
  }
}
