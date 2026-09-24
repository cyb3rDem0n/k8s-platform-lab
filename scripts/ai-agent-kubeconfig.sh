#!/usr/bin/env bash
# Crea un kubeconfig SOLA LETTURA (ServiceAccount ai-agent-readonly) da dare a strumenti AI
# (k8sgpt, server MCP, assistenti). Il token scade: rigeneralo quando serve.
# Uso: scripts/ai-agent-kubeconfig.sh [durata] > ~/.kube/config-ai-readonly
set -euo pipefail
duration="${1:-8h}"
server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
ca=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
token=$(kubectl -n ai create token ai-agent-readonly --duration "$duration")
cat <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
  - name: k8s-platform-lab
    cluster:
      server: ${server}
      certificate-authority-data: ${ca}
users:
  - name: ai-agent-readonly
    user:
      token: ${token}
contexts:
  - name: ai-readonly
    context: { cluster: k8s-platform-lab, user: ai-agent-readonly }
current-context: ai-readonly
KUBECONFIG
