# Capitolo 15 — Verso il cloud: AWS, Google Cloud, Azure

Questo capitolo chiude la parte on‑premise e prepara la prossima. Non installa nulla: costruisce
la mappa mentale che userai per portare la stessa piattaforma su EKS, GKE e AKS, nell'ordine.

## 15.1 Cosa cambia e cosa resta

In un cluster gestito, il provider si occupa del control plane: etcd, API server, scheduler,
aggiornamenti, backup del control plane, alta disponibilità. Tu non vedi più i static Pod del
capitolo 2 e non rinnovi i certificati del capitolo 14. In cambio, il cluster si integra con i
servizi del cloud: rete, bilanciatori, dischi, identità.

Riprendendo gli strati del capitolo 0:

```
  Strato                 NUC (oggi)                         Cloud (prossima parte)
  ───────────────────────────────────────────────────────────────────────────────────────
  4. Carichi             Argo CD + gitops/ + k8s/apps/      IDENTICO (cambiano gli overlay)
  3. Piattaforma         Terraform 01/02 + Helm             Terraform, alcuni componenti diversi
  2. Cluster             kubeadm                            EKS / GKE / AKS via Terraform
  1. Sistema operativo   Ansible                            immagini gestite dei nodi
  0. Hardware            NUC                                VPC, subnet, zone di disponibilità
```

Tutto ciò che hai scritto per lo strato 4 sopravvive. È il ritorno dell'investimento fatto su
Kustomize, overlay e GitOps.

## 15.2 La corrispondenza, componente per componente

**Cluster.** kubeadm diventa **Amazon EKS**, **Google Kubernetes Engine** (modalità Standard o
Autopilot) o **Azure Kubernetes Service**, creati con Terraform (moduli ufficiali o della
community per ciascun provider). I nodi sono gruppi gestiti di macchine virtuali, o del tutto
astratti (EKS Auto Mode, GKE Autopilot, AKS Automatic).

**Rete dei Pod.** Calico lascia il posto al CNI nativo: VPC CNI su EKS (i Pod prendono IP della
VPC), GKE Dataplane V2 basato su Cilium, Azure CNI (con overlay o powered by Cilium). La
conseguenza pratica: i Pod possono avere IP instradabili nella rete del cloud, e la
pianificazione degli indirizzi diventa un tema serio. Le NetworkPolicy del capitolo 7 restano
valide, a patto che il CNI scelto le applichi (su EKS va abilitato esplicitamente).

**Load balancer.** MetalLB non serve più. Un Service `LoadBalancer` crea un bilanciatore del
cloud: su EKS tramite l'**AWS Load Balancer Controller** (Network Load Balancer), su GKE e AKS
tramite l'integrazione nativa. Il nostro Gateway NGINX continua a funzionare: il suo Service
riceverà un NLB/bilanciatore invece di un IP di MetalLB. In alternativa si possono usare le
implementazioni Gateway API dei provider (GKE Gateway controller, Application Gateway for
Containers su Azure, AWS Gateway API Controller basato su VPC Lattice). Questa sarà una delle
scelte architetturali da discutere, cloud per cloud.

**Storage.** `local-path` diventa il driver CSI del provider: **EBS** su AWS, **Persistent
Disk** su GCP, **Azure Disk** su Azure. Le PVC restano identiche, cambia la `storageClassName`
(in un overlay). I dischi sopravvivono al nodo, si possono fare snapshot e ridimensionare.

**Registry.** GHCR resta utilizzabile; in alternativa **ECR**, **Artifact Registry**, **ACR**,
con il vantaggio che i nodi scaricano le immagini tramite la loro identità cloud, senza pull
secret.

**Identità dei Pod: la differenza più importante.** Sul NUC nessun Pod ha bisogno di parlare
con servizi esterni autenticati. Nel cloud, il controller del load balancer, il driver CSI,
External Secrets e le tue applicazioni devono chiamare API del cloud. La risposta sbagliata è una
chiave di accesso in un Secret. La risposta giusta è la **federazione di identità**: il
ServiceAccount Kubernetes viene associato a un'identità del cloud, e il Pod ottiene credenziali
temporanee senza segreti statici. Su AWS **EKS Pod Identity** (o il precedente IRSA), su GCP
**Workload Identity Federation for GKE**, su Azure **Microsoft Entra Workload ID**. Il principio
è lo stesso del ServiceAccount in sola lettura del capitolo 12: identità dedicata, permessi
minimi, credenziali a scadenza.

**Segreti.** Sealed Secrets diventa **External Secrets Operator** (sezione 11.9) collegato a
**AWS Secrets Manager**, **Google Secret Manager** o **Azure Key Vault**, con l'accesso concesso
tramite l'identità del punto precedente. La cifratura a riposo di etcd si attiva con il KMS del
provider (sezione 11.8, provider KMS v2).

**TLS e DNS.** La CA interna del lab lascia il posto a **Let's Encrypt** con cert-manager (sfida
DNS‑01 sul DNS del provider: Route 53, Cloud DNS, Azure DNS) e a un dominio vero. **ExternalDNS**
crea da solo i record DNS a partire dagli hostname delle HTTPRoute: niente più `/etc/hosts`.

**Stato di Terraform.** Lo stato locale diventa remoto e condiviso, con locking: bucket **S3**
(con lock nativo), **GCS**, o **Azure Storage**. Senza, due persone (o una persona e una
pipeline) che lanciano `apply` insieme possono corrompere lo stato.

**Osservabilità.** kube-prometheus-stack continua a funzionare, ma ogni provider offre servizi
gestiti (Amazon Managed Service for Prometheus, Google Cloud Managed Service for Prometheus,
Azure Monitor managed service for Prometheus, più le rispettive soluzioni di log e Grafana
gestite). Scegliere tra gestito e self‑managed è una decisione di costi e competenze.

**Costi.** Sul NUC il costo è l'elettricità. Nel cloud ogni componente ha un prezzo orario:
control plane (dove si paga), nodi, bilanciatori, NAT gateway, dischi, traffico in uscita. Prima
di creare qualunque cosa imposteremo budget e allarmi di spesa, e ogni capitolo cloud terminerà
con `terraform destroy`.

## 15.3 Come si prepara il repository al multi‑ambiente

Il lavoro concreto sul repository sarà modesto, grazie alla struttura attuale:

- `terraform/` diventerà `terraform/onprem/`, `terraform/aws/`, `terraform/gcp/`, `terraform/azure/`,
  ciascuno con i suoi stadi e uno stato remoto.
- `k8s/apps/hello/overlays/` avrà `lab`, `aws`, `gcp`, `azure`: cambiano storage class, hostname,
  eventuali annotazioni del bilanciatore, il riferimento ai segreti (ExternalSecret invece di
  SealedSecret).
- Argo CD potrà gestire più cluster da un'unica istanza. L'**ApplicationSet** genera
  un'Application per ogni cluster registrato (generatore `clusters`) o per ogni cartella
  (generatore `git`), eliminando la duplicazione dei file in `gitops/apps/`.

## 15.4 Il piano delle prossime parti

1. **AWS.** VPC su tre zone con Terraform, EKS con managed node group, AWS Load Balancer
   Controller, EBS CSI, EKS Pod Identity, ECR, External Secrets con Secrets Manager, stato su S3,
   cert-manager con Route 53, lo stesso Argo CD e la stessa app.
2. **Google Cloud.** GKE Standard e confronto con Autopilot, Workload Identity Federation,
   Gateway API nativo di GKE a confronto con NGINX Gateway Fabric, Artifact Registry, Secret
   Manager, stato su GCS.
3. **Azure.** AKS, Entra Workload ID, Application Gateway for Containers a confronto con NGF,
   ACR, Key Vault, stato su Azure Storage.
4. **Multi‑cluster.** Argo CD con ApplicationSet che governa NUC e cloud, promozione di una
   release tra ambienti tramite Git.

## 15.5 Prima di partire

Verifica di saper fare senza consultare il tutorial le voci dell'Appendice D. Se una manca,
torna al capitolo relativo: nel cloud ogni problema del livello 4 sarà lo stesso di qui, ma con
più strati sotto in cui cercarlo.

<!-- nav -->
---

[← Capitolo 14 — Operazioni day‑2](14-operazioni-day2.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Appendici →](16-appendici.md)
