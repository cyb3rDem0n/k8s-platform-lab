#!/usr/bin/env bash
# Genera un token casuale, crea il Secret del backend IN MEMORIA e lo cifra con la chiave
# pubblica del controller Sealed Secrets. Solo il file cifrato finisce su disco (e in Git).
#
# Requisiti: kubectl con accesso al cluster, kubeseal, openssl.
# Uso: scripts/seal-backend-secret.sh            (token casuale)
#      API_TOKEN=... scripts/seal-backend-secret.sh
set -euo pipefail
out="k8s/apps/hello/overlays/lab/sealed-backend-secret.yaml"
token="${API_TOKEN:-$(openssl rand -hex 24)}"

kubectl create secret generic hello-backend-secret \
  --namespace hello \
  --from-literal=API_TOKEN="$token" \
  --dry-run=client -o yaml \
| kubeseal \
  --controller-name sealed-secrets-controller \
  --controller-namespace kube-system \
  --format yaml > "$out"

echo "Creato $out (cifrato: si può committare)."
echo "Token in chiaro (salvalo nel tuo password manager, NON in Git): $token"
echo "Ora: decommenta 'sealed-backend-secret.yaml' in k8s/apps/hello/overlays/lab/kustomization.yaml, commit e push."
