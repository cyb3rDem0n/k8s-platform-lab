# gitops/optional — componenti da attivare quando arrivi al capitolo corrispondente

Per attivarne uno: spostalo (git mv) in `gitops/apps/`, fai commit e push. Argo CD lo installa.
Per disattivarlo: rimettilo qui. Con `prune: true` Argo CD rimuove tutto ciò che aveva creato.

- `monitoring.yaml` — kube-prometheus-stack (Prometheus, Alertmanager, Grafana). Pesante: ~1.5 GB RAM.
  Controlla l'ultima versione del chart con `scripts/check-versions.sh` e aggiorna `targetRevision`.
- `hello-helm.yaml` — la variante Helm dell'app (chart `charts/hello`) nel namespace `hello-helm`,
  raggiungibile su `hello-helm.lab.home.arpa`. Capitolo 5B.
