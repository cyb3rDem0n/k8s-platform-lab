# Appendici

## Appendice A — Glossario

- **Admission controller** — componente dell'API server che valida o modifica le richieste dopo
  autenticazione e autorizzazione (es. Pod Security Admission).
- **App of apps** — Application di Argo CD che punta a una cartella contenente altre Application.
- **Chart** — pacchetto Helm: template, valori di default, metadati e dipendenze, con una versione propria distinta da quella dell'app.
- **CNI** — Container Network Interface: standard dei plugin che danno rete ai Pod (Calico).
- **Controller** — processo che riconcilia lo stato reale con quello desiderato, in un ciclo continuo.
- **CRD** — Custom Resource Definition: estende l'API di Kubernetes con nuovi tipi.
- **CRI** — Container Runtime Interface: API tra kubelet e runtime (containerd).
- **Drift** — differenza tra lo stato dichiarato (Git, Terraform) e quello reale.
- **EndpointSlice** — elenco degli IP dei Pod pronti dietro un Service.
- **Gateway API** — l'API standard di routing L4/L7, successore di Ingress: GatewayClass, Gateway, HTTPRoute.
- **GitOps** — modello operativo in cui Git è la fonte di verità e un agente nel cluster la applica (pull).
- **Helm** — package manager di Kubernetes: installa chart parametrizzati come release, con storia delle revisioni e rollback.
- **HPA** — HorizontalPodAutoscaler: scala il numero di repliche in base a metriche.
- **Idempotenza** — proprietà per cui ripetere un'operazione produce lo stesso risultato.
- **Kustomize** — composizione di manifest YAML con base, overlay, patch e componenti, senza template.
- **MCP** — Model Context Protocol: standard con cui un'applicazione AI accede a strumenti e dati.
- **NetworkPolicy** — regole L3/L4 su quali Pod possono comunicare tra loro.
- **PDB** — PodDisruptionBudget: limita le interruzioni volontarie simultanee.
- **Probe** — controllo periodico del kubelet: startup, liveness, readiness.
- **PSA** — Pod Security Admission: applica i profili privileged, baseline, restricted per namespace.
- **QoS class** — Guaranteed, Burstable, BestEffort: derivata da requests e limits, decide chi viene sfrattato per primo.
- **Release (Helm)** — istanza di un chart installata con un nome in un namespace; ogni install, upgrade o rollback crea una revisione.
- **Reconciliation** — il ciclo osserva, confronta, agisci.
- **SealedSecret** — Secret cifrato con la chiave pubblica del controller, sicuro da committare.
- **Static Pod** — Pod avviato dal kubelet da un file su disco, senza API server (il control plane di kubeadm).
- **Sync wave** — ordinamento delle risorse in un sync di Argo CD.
- **Taint / toleration** — il nodo respinge i Pod che non tollerano il suo taint.

## Appendice B — Comandi di riferimento

**Contesto e orientamento**

```bash
kubectl config get-contexts && kubectl config use-context <ctx>
kubectl get all -n hello
kubectl api-resources | grep -i gateway
kubectl explain deployment.spec.strategy --recursive
```

**Diagnosi**

```bash
kubectl describe pod <pod>                    # Events in fondo
kubectl logs <pod> [-c container] [--previous] [-f]
kubectl events -n hello --for pod/<pod>
kubectl get endpointslice -n hello -l kubernetes.io/service-name=hello-backend
kubectl exec -it <pod> -- sh                  # non funziona su distroless: usa kubectl debug
kubectl debug -it <pod> --image=busybox:1.37 --target=backend
kubectl port-forward svc/hello-backend 8080:8080 -n hello
kubectl top pods -n hello --containers
kubectl auth can-i --list --as=system:serviceaccount:ai:ai-agent-readonly
```

**Rollout**

```bash
kubectl rollout status deploy/hello-backend -n hello
kubectl rollout history deploy/hello-backend -n hello
kubectl rollout undo deploy/hello-backend -n hello        # fuori da GitOps; con Argo CD usa git revert
kubectl rollout restart deploy/hello-backend -n hello
```

**Gateway API e TLS**

```bash
kubectl get gatewayclass,gateway -A
kubectl describe httproute -n hello hello                  # Accepted / ResolvedRefs
kubectl get certificate,certificaterequest -A
kubectl -n cert-manager get secret lab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-root-ca.crt
```

**Helm**

```bash
helm show values <chart> --version <v>                  # leggere PRIMA di installare
helm template <rel> <chart> -f valori.yaml              # rendere in locale
helm upgrade --install <rel> <chart> --version <v> -n <ns> -f valori.yaml --wait --rollback-on-failure
helm list -A ; helm status <rel> -n <ns> ; helm history <rel> -n <ns>
helm get values|manifest|notes <rel> -n <ns>
helm rollback <rel> <revisione> -n <ns> ; helm uninstall <rel> -n <ns>
helm lint --strict <cartella> ; helm test <rel> -n <ns>
helm package <cartella> ; helm push <chart>.tgz oci://ghcr.io/<utente>/charts
```

**Argo CD**

```bash
argocd login argocd.lab.home.arpa --grpc-web --username admin
argocd app list
argocd app get hello && argocd app diff hello
argocd app sync hello
```

**Terraform**

```bash
terraform init && terraform plan -out tfplan && terraform apply tfplan
terraform state list && terraform state show <risorsa>
terraform plan -refresh-only          # rileva il drift senza cambiare nulla
```

**Nodo (kubeadm)**

```bash
sudo kubeadm certs check-expiration
sudo crictl ps -a && sudo crictl logs <id>
journalctl -u kubelet -e
```

## Appendice C — Domande da colloquio

Prova a rispondere a voce, in due minuti, senza guardare. Tra parentesi il capitolo dove trovi
la risposta.

1. Cosa succede, componente per componente, tra `kubectl apply` di un Deployment e il container in esecuzione? (1)
2. Perché il kubelet richiede lo swap disattivato e perché il driver cgroup deve coincidere col runtime? (2)
3. Come fa kubeadm ad avviare un control plane che gira come Pod se l'API server non esiste ancora? (2)
4. Che cosa rende idempotente un playbook? Come lo dimostri? (3)
5. Differenza tra liveness, readiness e startup probe. Cosa succede se la liveness controlla una dipendenza esterna? (4, 5)
6. Come si ottiene uno shutdown senza errori durante un rolling update? (4, 5)
7. Perché spesso non si mette il limit di CPU ma sempre quello di memoria? Cosa sono le classi di QoS? (5)
8. NodePort, LoadBalancer, Gateway: quando e perché ciascuno? Cosa fa MetalLB in modalità L2? (6)
9. Perché ingress-nginx è stato ritirato e cosa porta di diverso il Gateway API? (6)
10. Scrivi a voce una NetworkPolicy default-deny e dimmi cosa si rompe per primo (DNS). (7)
11. Come calcola l'HPA il numero di repliche? Perché serve `ignoreDifferences` con Argo CD? (8, 10)
12. Cos'è lo stato di Terraform, cosa contiene e dove va tenuto in team? Perché due stadi con le CRD? (9)
13. Modello push vs pull nel deploy: perché la CI non dovrebbe avere credenziali del cluster? (10)
14. Come si mettono i segreti in un repository GitOps? Confronta Sealed Secrets ed External Secrets. (11)
15. Cosa succede ai SealedSecret se perdi la chiave del controller? (11, 14)
16. Come dai accesso a un agente AI al cluster in modo sicuro? Cos'è la prompt injection in questo contesto? (12)
17. `rate()` su un counter: perché, e perché prima di `sum`? (13)
18. Come aggiorni un cluster kubeadm di una minor? Cosa controlli prima? (14)
19. Il cluster è irraggiungibile dopo un anno esatto dall'installazione. Causa probabile e rimedio? (14)
20. Portando questa piattaforma su EKS, cosa cambia e cosa resta uguale? (15)
21. Differenza tra `version` e `appVersion` in un chart? Perché il selettore di un Deployment non deve contenere la versione? (5B)
22. Cosa cambia tra un chart installato con `helm install`, con Terraform `helm_release` e con Argo CD? (5B, 9, 10)
23. Perché Helm non aggiorna le CRD nella cartella `crds/`, e come lo gestisce cert-manager? (5B)

## Appendice D — Checklist delle competenze

Spunta solo ciò che sai fare senza guardare il tutorial.

**Cluster**
- [ ] Preparo un nodo e creo un cluster con kubeadm da un file di configurazione
- [ ] Installo un CNI e ne verifico il funzionamento
- [ ] Automatizzo il provisioning con Ansible e dimostro l'idempotenza con reset e rebuild

**Applicazione**
- [ ] Scrivo un Dockerfile multi-stage con immagine finale minimale e non-root
- [ ] Scrivo un Deployment con probe, risorse, securityContext e strategia di rollout motivate
- [ ] Uso chart di terzi con versione bloccata e valori in file; scrivo un chart con helper, schema dei valori e `helm test`
- [ ] Diagnostico Pending, ImagePullBackOff, CrashLoopBackOff, OOMKilled, Service senza endpoint

**Rete ed esposizione**
- [ ] Espongo un servizio con NodePort, LoadBalancer (MetalLB) e Gateway API
- [ ] Configuro TLS con cert-manager e una CA, e spiego il percorso di un pacchetto dal client al Pod
- [ ] Applico NetworkPolicy default-deny e apro solo i flussi necessari

**Automazione**
- [ ] Gestisco la piattaforma con Terraform, leggo un plan e correggo un drift
- [ ] Configuro Argo CD con app-of-apps, sync wave, hook, prune e self-heal
- [ ] Costruisco una pipeline CI che pubblica immagini e aggiorna i tag in Git

**Strumenti**
- [ ] Gestisco segreti con Sealed Secrets, ne faccio backup e rotazione
- [ ] Eseguo un LLM nel cluster e lo integro in un'applicazione con isolamento di rete
- [ ] Uso k8sgpt e do a un agente AI un accesso in sola lettura con token a scadenza
- [ ] Raccolgo metriche applicative con Prometheus e scrivo query PromQL e allarmi

**Operazioni**
- [ ] Aggiorno Kubernetes di una minor con kubeadm
- [ ] Faccio e so ripristinare uno snapshot di etcd; controllo e rinnovo i certificati
- [ ] Ricostruisco l'intera piattaforma da zero seguendo l'ordine corretto

<!-- nav -->
---

[← Capitolo 15 — Verso il cloud: AWS, Google Cloud, Azure](15-verso-il-cloud.md)  ·  [Indice](../../TUTORIAL.md)
