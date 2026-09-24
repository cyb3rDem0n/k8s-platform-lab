# =============================================================================================
# Stadio 01 — PIATTAFORMA: installa i controller (Helm) e le CRD.
# Le risorse che USANO quelle CRD (IPAddressPool, ClusterIssuer, Gateway, Application...) stanno
# nello stadio 02: il provider kubernetes valida i manifest al plan, quando le CRD ancora non esistono.
# =============================================================================================

locals {
  kubectl_env = { KUBECONFIG = pathexpand(var.kubeconfig_path) }
}

# ---------------------------------------------------------------------------------------------
# Gateway API CRDs (standard channel). Non sono un chart Helm: le applichiamo con kubectl.
# --server-side: le CRD sono grandi e superano il limite dell'annotazione last-applied.
# ---------------------------------------------------------------------------------------------
resource "terraform_data" "gateway_api_crds" {
  triggers_replace = [var.versions.gateway_api]

  provisioner "local-exec" {
    environment = local.kubectl_env
    command     = "kubectl apply --server-side --force-conflicts -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.versions.gateway_api}/standard-install.yaml"
  }
}

# ---------------------------------------------------------------------------------------------
# Storage: local-path-provisioner crea PersistentVolume come directory sul disco del nodo.
# Lo marchiamo come StorageClass di default: le PVC senza storageClassName lo useranno.
# ---------------------------------------------------------------------------------------------
resource "terraform_data" "local_path_provisioner" {
  triggers_replace = [var.versions.local_path_provisioner]

  provisioner "local-exec" {
    environment = local.kubectl_env
    command     = <<-EOT
      kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/${var.versions.local_path_provisioner}/deploy/local-path-storage.yaml
      kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    EOT
  }
}

# ---------------------------------------------------------------------------------------------
# metrics-server: fonte delle metriche CPU/RAM per `kubectl top` e per l'HorizontalPodAutoscaler.
# ---------------------------------------------------------------------------------------------
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.versions.metrics_server_chart
  values     = [file("${path.module}/values/metrics-server.yaml")]
}

# ---------------------------------------------------------------------------------------------
# MetalLB: implementa i Service type=LoadBalancer sul bare metal (modalità L2/ARP).
# Lo speaker usa hostNetwork: il namespace deve essere "privileged" per Pod Security Admission.
# ---------------------------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "metallb" {
  metadata {
    name = "metallb-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "metallb" {
  name       = "metallb"
  namespace  = kubernetes_namespace_v1.metallb.metadata[0].name
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  version    = var.versions.metallb_chart
  wait       = true
}

# ---------------------------------------------------------------------------------------------
# cert-manager: emette e rinnova certificati TLS. Con enableGatewayAPI legge le annotazioni
# dei Gateway e crea da solo i Certificate per i listener HTTPS.
# ---------------------------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.versions.cert_manager_chart
  values           = [file("${path.module}/values/cert-manager.yaml")]
  wait             = true

  # cert-manager deve vedere le CRD del Gateway API all'avvio per attivare quel controller.
  depends_on = [terraform_data.gateway_api_crds]
}

# ---------------------------------------------------------------------------------------------
# NGINX Gateway Fabric: implementazione del Gateway API con NGINX come data plane.
# Sostituisce ingress-nginx (ritirato a marzo 2026). Crea un Deployment+Service di NGINX
# per ogni Gateway; il Service è LoadBalancer -> riceve un IP da MetalLB.
# ---------------------------------------------------------------------------------------------
resource "helm_release" "nginx_gateway_fabric" {
  name             = "ngf"
  namespace        = "nginx-gateway"
  create_namespace = true
  repository       = "oci://ghcr.io/nginx/charts"
  chart            = "nginx-gateway-fabric"
  version          = var.versions.ngf_chart
  values           = [file("${path.module}/values/nginx-gateway-fabric.yaml")]
  wait             = true

  depends_on = [terraform_data.gateway_api_crds, helm_release.metallb]
}

# ---------------------------------------------------------------------------------------------
# Argo CD: il motore GitOps. Terraform lo INSTALLA (bootstrap); da quel momento sono le
# Application nel repo Git a dire cosa gira nel cluster.
# ---------------------------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.versions.argocd_chart
  values = [templatefile("${path.module}/values/argocd.yaml.tftpl", {
    argocd_host = "argocd.${var.base_domain}"
  })]
  wait = true
}
