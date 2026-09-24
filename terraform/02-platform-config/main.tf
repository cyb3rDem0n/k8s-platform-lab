# =============================================================================================
# Stadio 02 — CONFIGURAZIONE della piattaforma: oggetti che usano le CRD installate nello stadio 01.
# I manifest sono file YAML leggibili in manifests/, parametrizzati con templatefile().
# =============================================================================================

locals {
  tpl_vars = {
    base_domain           = var.base_domain
    metallb_address_range = var.metallb_address_range
    gitops_repo_url       = var.gitops_repo_url
    gitops_revision       = var.gitops_revision
  }
  m = { for f in fileset("${path.module}/manifests", "*.yaml") :
    trimsuffix(f, ".yaml") => yamldecode(templatefile("${path.module}/manifests/${f}", local.tpl_vars))
  }
}

# ---- MetalLB: quali IP può usare e come annunciarli (L2 = risponde alle richieste ARP) --------
resource "kubernetes_manifest" "metallb_pool" {
  manifest = local.m["metallb-ipaddresspool"]
}

resource "kubernetes_manifest" "metallb_l2" {
  manifest   = local.m["metallb-l2advertisement"]
  depends_on = [kubernetes_manifest.metallb_pool]
}

# ---- PKI del laboratorio: self-signed -> CA radice -> ClusterIssuer "lab-ca" -----------------
resource "kubernetes_manifest" "issuer_selfsigned" {
  manifest = local.m["issuer-selfsigned"]
}

resource "kubernetes_manifest" "lab_root_ca" {
  manifest   = local.m["certificate-lab-root-ca"]
  depends_on = [kubernetes_manifest.issuer_selfsigned]

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

resource "kubernetes_manifest" "issuer_lab_ca" {
  manifest   = local.m["issuer-lab-ca"]
  depends_on = [kubernetes_manifest.lab_root_ca]
}

# ---- Gateway condiviso: ingresso unico del cluster (HTTP 80 + HTTPS 443 wildcard) -----------
resource "kubernetes_manifest" "gateway" {
  manifest   = local.m["gateway"]
  depends_on = [kubernetes_manifest.issuer_lab_ca, kubernetes_manifest.metallb_l2]
}

# ---- Route per la UI di Argo CD --------------------------------------------------------------
resource "kubernetes_manifest" "argocd_route" {
  manifest   = local.m["httproute-argocd"]
  depends_on = [kubernetes_manifest.gateway]
}

# ---- GitOps: da qui in poi il repository Git è la fonte di verità (capitolo 10) ---------------
resource "kubernetes_manifest" "argocd_project" {
  count    = var.enable_gitops ? 1 : 0
  manifest = local.m["argocd-appproject"]
}

resource "kubernetes_manifest" "argocd_root_app" {
  count      = var.enable_gitops ? 1 : 0
  manifest   = local.m["argocd-root-application"]
  depends_on = [kubernetes_manifest.argocd_project]
}
