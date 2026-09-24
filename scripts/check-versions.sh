#!/usr/bin/env bash
# Confronta le versioni BLOCCATE nel repo con le ultime pubblicate.
# Non aggiorna nulla: aggiornare è una decisione (leggi il changelog, poi commit dedicato).
# Requisiti: curl, jq, helm.
set -uo pipefail
gh_latest() { curl -fsSL "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name; }
helm_latest() {
  helm repo add "$1" "$2" >/dev/null 2>&1; helm repo update "$1" >/dev/null 2>&1
  helm search repo "$1/$3" -o json | jq -r '.[0].version'
}
row() { printf '%-26s %-14s %-14s %s\n' "$1" "$2" "$3" "$([ "$2" = "$3" ] && echo '' || echo '<- aggiornabile')"; }

printf '%-26s %-14s %-14s\n' COMPONENTE BLOCCATA ULTIMA
row "helm CLI (installata)"  "$(helm version --template '{{.Version}}' 2>/dev/null)" "$(gh_latest helm/helm)"
row "kubernetes (minor)"     "$(grep -oP 'k8s_minor: "\K[^"]+' ansible/inventory/group_vars/k8s.yml)" "$(curl -fsSL https://dl.k8s.io/release/stable.txt | cut -d. -f1,2)"
row "calico"                 "$(grep -oP 'calico_version: "\K[^"]+' ansible/inventory/group_vars/k8s.yml)" "$(gh_latest projectcalico/calico)"
row "gateway-api"            "$(grep -oP 'gateway_api\s+= "\K[^"]+' terraform/01-platform/variables.tf)" "$(gh_latest kubernetes-sigs/gateway-api)"
row "local-path-provisioner" "$(grep -oP 'local_path_provisioner\s+= "\K[^"]+' terraform/01-platform/variables.tf)" "$(gh_latest rancher/local-path-provisioner)"
row "nginx-gateway-fabric"   "$(grep -oP 'ngf_chart\s+= "\K[^"]+' terraform/01-platform/variables.tf)" "$(gh_latest nginx/nginx-gateway-fabric | sed 's/^v//')"
row "metrics-server chart"   "$(grep -oP 'metrics_server_chart\s+= "\K[^"]+' terraform/01-platform/variables.tf)" "$(helm_latest metrics-server https://kubernetes-sigs.github.io/metrics-server/ metrics-server)"
row "metallb chart"          "$(grep -oP 'metallb_chart\s+= "\K[^"]+' terraform/01-platform/variables.tf)" "$(helm_latest metallb https://metallb.github.io/metallb metallb)"
row "cert-manager chart"     "$(grep -oP 'cert_manager_chart\s+= "\K[^"]+' terraform/01-platform/variables.tf)" "$(helm_latest jetstack https://charts.jetstack.io cert-manager)"
row "argo-cd chart"          "$(grep -oP 'argocd_chart\s+= "\K[^"]+' terraform/01-platform/variables.tf)" "$(helm_latest argo https://argoproj.github.io/argo-helm argo-cd)"
row "sealed-secrets chart"   "$(grep -oP 'targetRevision: \K\S+' gitops/apps/sealed-secrets.yaml)" "$(helm_latest sealed-secrets https://bitnami-labs.github.io/sealed-secrets sealed-secrets)"
row "kube-prometheus-stack"  "$(grep -oP 'targetRevision: "\K[^"]+' gitops/optional/monitoring.yaml)" "$(helm_latest prometheus-community https://prometheus-community.github.io/helm-charts kube-prometheus-stack)"
row "ollama"                 "$(grep -oP 'ollama/ollama:\K\S+' k8s/apps/ai/ollama/deployment.yaml)" "$(gh_latest ollama/ollama | sed 's/^v//')"
