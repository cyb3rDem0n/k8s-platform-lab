# k8s-platform-lab

Una piattaforma Kubernetes completa costruita da zero su un singolo mini‑PC (un Intel NUC),
con gli stessi strumenti e le stesse pratiche che si usano in produzione: provisioning
automatizzato, infrastruttura come codice, GitOps, gestione dei segreti, sicurezza di rete,
osservabilità e un LLM che gira dentro il cluster.

Il repository è insieme **codice funzionante** e **corso**. Il corso completo, con teoria e
pratica passo per passo, parte da [`TUTORIAL.md`](TUTORIAL.md) (l'indice) ed è diviso in un file
per capitolo in [`docs/tutorial/`](docs/tutorial/). Questo README è la mappa.

> Stato delle versioni: verificate a settembre 2026. `make versions` confronta le versioni
> bloccate nel repo con le ultime pubblicate.

---

## Cosa costruisci

```
                         Internet / LAN di casa
                                  │
                        ┌─────────▼──────────┐   IP assegnato da MetalLB (L2/ARP)
                        │  Gateway NGINX     │   TLS terminato con certificato di cert-manager
                        │  (Gateway API)     │   *.lab.home.arpa
                        └──┬───────────┬─────┘
            hello.lab…/api │           │ hello.lab…/          argocd.lab…
                  ┌────────▼───┐  ┌────▼────────┐        ┌──────────────┐
                  │ backend    │  │ frontend    │        │  Argo CD UI  │
                  │ Java 25    │  │ nginx       │        └──────────────┘
                  │ (x2..x5)   │  │ (x2)        │
                  └─────┬──────┘  └─────────────┘
                        │  NetworkPolicy: solo backend → LLM
                  ┌─────▼──────┐
                  │ Ollama LLM │  namespace ai, modello su PersistentVolume
                  └────────────┘

   Chi gestisce cosa:
   Ansible   → sistema operativo, containerd, kubeadm, Calico           (il NODO)
   Terraform → MetalLB, cert-manager, NGINX Gateway Fabric, Argo CD…    (la PIATTAFORMA)
   Argo CD   → applicazioni, Sealed Secrets, LLM, monitoring            (i CARICHI, da Git)
   GitHub Actions → build immagini + commit del nuovo tag               (la CI; non tocca il cluster)
```

La regola che regge tutto: **ogni risorsa ha un solo proprietario**. Se due strumenti gestiscono
la stessa cosa, prima o poi si combattono.

## Stack

- **Nodo**: Ubuntu Server 24.04 LTS, containerd 2.x, Kubernetes v1.36 con kubeadm, Calico (CNI con NetworkPolicy), kube-proxy in modalità nftables.
- **Esposizione**: MetalLB per i Service LoadBalancer su bare metal; Gateway API con **NGINX Gateway Fabric** (ingress-nginx è stato ritirato a marzo 2026 e non va più usato su installazioni nuove); cert-manager con una CA interna.
- **Applicazione**: backend Java 25 senza framework (solo JDK, virtual thread, immagine jlink+distroless da ~50 MB, non-root, filesystem read-only); frontend statico servito da nginx unprivileged.
- **Packaging**: Kustomize per l'app sul percorso GitOps; un chart Helm 4 della stessa app (con `values.schema.json`, checksum della config, `helm test`), pubblicabile su GHCR come artefatto OCI.
- **IaC e GitOps**: Terraform (provider Helm 3.x e Kubernetes 3.x) in due stadi; Argo CD con pattern app-of-apps, sync wave e hook.
- **Segreti**: Sealed Secrets (Secret cifrati, committabili in Git); percorso verso External Secrets Operator per il cloud.
- **AI**: Ollama nel cluster con un modello piccolo servito su CPU; endpoint `/api/ask` del backend; k8sgpt per la diagnosi; un'identità RBAC in sola lettura per agenti e server MCP.
- **Qualità**: NetworkPolicy default‑deny, Pod Security Admission `restricted`, probe, HPA, PDB, graceful shutdown, CI con validazione dei manifest, `terraform validate` e `ansible-lint` (profilo production).

## Struttura

```
.
├── TUTORIAL.md                     indice del corso
├── docs/tutorial/                  17 capitoli (00–15, più 5B su Helm) + appendici, un file ciascuno
├── Makefile                        make help
├── charts/hello/                  la stessa app come chart Helm 4 (schema dei valori, helm test)
├── app/
│   ├── backend/                    Java 25, Dockerfile multi-stage (jlink + distroless)
│   └── frontend/                   nginx unprivileged + pagina statica
├── ansible/                        provisioning del nodo: site.yml, reset.yml, 4 ruoli
├── terraform/
│   ├── 01-platform/                controller e CRD (Helm): MetalLB, cert-manager, NGF, Argo CD…
│   └── 02-platform-config/         oggetti che usano quelle CRD: pool IP, PKI, Gateway, root app
├── k8s/
│   ├── apps/hello/
│   │   ├── base/{core,network,routing}   l'app divisa in strati applicabili separatamente
│   │   ├── overlays/lab/                 ambiente "lab": tag immagini, patch (sincronizzato da Argo CD)
│   │   └── components/monitoring/        componente Kustomize opzionale (ServiceMonitor)
│   ├── apps/ai/ollama/             LLM nel cluster + Job PostSync che scarica il modello
│   ├── apps/ai/agent-rbac/         ServiceAccount in sola lettura per strumenti AI
│   └── learn/                      manifest didattici (NodePort, LoadBalancer, pod di debug, stage 05)
├── gitops/
│   ├── apps/                       Application Argo CD (lette dalla root app)
│   └── optional/                   componenti da attivare spostandoli in apps/ (monitoring)
├── scripts/                        set-repo-url, seal-backend-secret, smoke-test, check-versions…
├── docker-compose.yml              sviluppo locale senza cluster
└── .github/workflows/ci.yml        validate → build & push (GHCR) → bump tag nell'overlay
```

## Prerequisiti

Il nodo: un NUC (o qualunque PC/VM x86_64) con almeno 4 core, **16 GB di RAM** (8 GB bastano
senza LLM e senza monitoring), 100 GB di SSD, Ubuntu Server 24.04 installato, IP fisso o
riservato sul router, accesso SSH con chiave e `sudo`.

La tua macchina: `git`, `docker` (o Podman), `kubectl`, `helm`, `terraform` ≥ 1.9,
`ansible-core`, `kubeseal`, `jq`. Facoltativi: `argocd` CLI, `k8sgpt`, `kustomize`, `kubeconform`.

Un account GitHub (per il repository, le Actions e il registry GHCR).

## Avvio rapido

Per chi vuole prima vedere tutto funzionare e poi studiarlo. Il tutorial segue invece un
percorso manuale → automatizzato, capitolo per capitolo.

```bash
# 0. Fork del repo su GitHub, poi:
git clone https://github.com/<tu>/k8s-platform-lab.git && cd k8s-platform-lab
scripts/set-repo-url.sh <tu>              # sostituisce YOUR_GH_USER ovunque
git commit -am "chore: set repo owner" && git push
# La prima esecuzione delle Actions pubblica le immagini su GHCR: rendile pubbliche
# (GitHub → Packages → Package settings → Change visibility) oppure configura un pull secret.

# 1. Nodo (IP e utente in ansible/inventory/hosts.ini)
make cluster
export KUBECONFIG=~/.kube/config-nuc && kubectl get nodes

# 2. Piattaforma
cp terraform/02-platform-config/terraform.tfvars.example terraform/02-platform-config/terraform.tfvars
#    → imposta metallb_address_range su IP LIBERI della tua LAN, fuori dal DHCP
make platform
make platform-config

# 3. GitOps: in terraform.tfvars imposta enable_gitops = true, poi
make platform-config                      # crea AppProject + root Application

# 4. DNS e fiducia nella CA
kubectl -n nginx-gateway get gateway lab-gateway   # leggi l'ADDRESS
echo "<ADDRESS> hello.lab.home.arpa argocd.lab.home.arpa" | sudo tee -a /etc/hosts
kubectl -n cert-manager get secret lab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-root-ca.crt

# 5. Verifica
make smoke
open https://argocd.lab.home.arpa         # utente admin, password: make argocd-password
```

Per attivare `/api/ask` servono il Secret (capitolo 11: `scripts/seal-backend-secret.sh`) e il
modello scaricato dal Job PostSync di Ollama (capitolo 12).

## Il flusso di un cambiamento

1. Modifichi il codice del backend e fai push su `main`.
2. La CI valida manifest, Terraform e Ansible, costruisce le immagini e le pubblica su GHCR con tag `0.1.<run>-<sha>`.
3. La CI committa il nuovo tag in `k8s/apps/hello/overlays/lab/kustomization.yaml`.
4. Argo CD vede il commit (entro 60 s), calcola la differenza e applica un rolling update.
5. Le readiness probe garantiscono zero downtime; se qualcosa va storto, il rollback è un `git revert`.

La CI non possiede credenziali del cluster. È il cluster che va a prendersi lo stato da Git
(modello *pull*): meno segreti in giro, audit completo nella storia di Git.

## Percorso del tutorial

| Parte | Capitoli | Cosa impari |
|---|---|---|
| Fondamenta | 0–3 | Architettura di Kubernetes, installazione manuale con kubeadm, automazione con Ansible |
| Applicazione | 4–5B | App cloud-native in Java, immagini sicure, primo deploy e debugging, Helm 4 (usare e scrivere chart) |
| Esposizione | 6 | port-forward → NodePort → LoadBalancer/MetalLB → Gateway API con NGINX → TLS |
| Hardening | 7–8 | NetworkPolicy, Pod Security, autoscaling, disruption budget |
| Automazione | 9–10 | Terraform per la piattaforma, Argo CD e GitOps, pipeline CI |
| Strumenti | 11–13 | Sealed Secrets, LLM nel cluster e k8sgpt, agenti AI con RBAC minimo, Prometheus/Grafana |
| Operazioni | 14 | Upgrade, backup di etcd, certificati, disaster recovery, troubleshooting |
| Oltre | 15 | Mappa verso AWS (EKS), Google Cloud (GKE) e Azure (AKS) |

## Roadmap: il cloud

La prossima parte porta la stessa applicazione e lo stesso modello GitOps sui tre cloud,
nell'ordine AWS → Google Cloud → Azure. Cambia lo strato sotto (cluster gestito, load balancer,
storage, identità, registry, secret manager); il repository Git e le Application di Argo CD
restano quasi identici. Il capitolo 15 del tutorial contiene la corrispondenza concetto per
concetto e il piano di lavoro.

- [ ] AWS: EKS con Terraform, AWS Load Balancer Controller, EBS CSI, EKS Pod Identity, ECR, External Secrets + Secrets Manager, stato Terraform su S3
- [ ] Google Cloud: GKE (Standard e Autopilot), Gateway GKE, Workload Identity Federation, Artifact Registry, Secret Manager, stato su GCS
- [ ] Azure: AKS, Application Gateway for Containers o NGF, Workload Identity, ACR, Key Vault, stato su Azure Storage
- [ ] Multi-cluster: un Argo CD che governa NUC + cloud con ApplicationSet

## Licenza

MIT — vedi [LICENSE](LICENSE).
