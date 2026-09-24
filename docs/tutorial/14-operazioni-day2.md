# Capitolo 14 — Operazioni day‑2

"Day 1" è l'installazione. "Day 2" è tutto quello che viene dopo e dura anni: aggiornare,
salvare, rinnovare, ripristinare, diagnosticare. È anche la parte che distingue chi ha *usato*
Kubernetes da chi lo ha *gestito*.

## 14.1 Aggiornare Kubernetes con kubeadm

**Le regole della version skew.** Si sale di **una minor alla volta** (1.36 → 1.37, mai
1.36 → 1.38). Il control plane si aggiorna per primo; il kubelet può essere più vecchio
dell'API server (fino a tre minor), mai più nuovo. kubectl tollera una minor di differenza in
entrambe le direzioni. Le patch (1.36.3 → 1.36.4) si possono applicare liberamente.

**Prima di cominciare:**

1. Leggi le release notes della minor di destinazione, in particolare la sezione "Urgent
   Upgrade Notes" e le API rimosse.
2. Controlla che i tuoi manifest non usino API deprecate o rimosse (strumenti come `pluto` o
   `kubent` le trovano; la CI con kubeconform aiuta se punti allo schema della nuova versione).
3. Verifica la compatibilità dei componenti di piattaforma: Calico, NGINX Gateway Fabric,
   cert-manager, Argo CD dichiarano le versioni di Kubernetes supportate.
4. **Fai uno snapshot di etcd** (14.2). Sempre.

**Procedura sul nodo control plane** (esempio 1.36 → 1.37):

```bash
nuc$ # 1. repository della nuova minor
nuc$ # kubernetes.sources se il nodo l'ha configurato Ansible, kubernetes.list se l'hai fatto a mano
nuc$ sudo sed -i 's#/v1.36/#/v1.37/#' /etc/apt/sources.list.d/kubernetes.*
nuc$ sudo apt-get update && apt-cache madison kubeadm | head -3

nuc$ # 2. kubeadm per primo
nuc$ sudo apt-mark unhold kubeadm && sudo apt-get install -y kubeadm='1.37.*' && sudo apt-mark hold kubeadm
nuc$ sudo kubeadm upgrade plan          # mostra cosa verrà aggiornato e verifica i requisiti
nuc$ sudo kubeadm upgrade apply v1.37.x # aggiorna i componenti del control plane e rinnova i certificati

nuc$ # 3. drain, kubelet e kubectl, uncordon
pc$  kubectl drain nuc --ignore-daemonsets --delete-emptydir-data
nuc$ sudo apt-mark unhold kubelet kubectl && sudo apt-get install -y kubelet='1.37.*' kubectl='1.37.*' \
       && sudo apt-mark hold kubelet kubectl
nuc$ sudo systemctl daemon-reload && sudo systemctl restart kubelet
pc$  kubectl uncordon nuc && kubectl get nodes
```

Su un cluster a nodo singolo il `drain` non ha dove spostare i Pod, e il PodDisruptionBudget del
backend (`minAvailable: 1`) lo bloccherà: è il comportamento corretto, il PDB sta facendo il suo
mestiere. Hai due scelte oneste: accettare qualche minuto di indisponibilità (salta il drain e
riavvia il kubelet: i Pod ripartono) oppure aggiungere un worker prima dell'upgrade. Con più
nodi si aggiornano i worker uno alla volta con `kubeadm upgrade node`.

Dopo l'upgrade, aggiorna `k8s_minor` in `ansible/inventory/group_vars/k8s.yml` e fai commit:
il playbook deve descrivere il cluster *com'è ora*, altrimenti la prossima ricostruzione
installerebbe la versione vecchia.

## 14.2 Backup di etcd

Lo snapshot di etcd contiene l'intero stato del cluster: ogni oggetto, ogni Secret (cifrato solo
se hai fatto la sezione 11.8). Sul nodo non c'è `etcdctl`, ma c'è dentro il Pod di etcd, che
monta `/var/lib/etcd` dal disco del nodo:

```bash
pc$ kubectl -n kube-system exec etcd-nuc -- etcdctl \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/server.crt \
      --key=/etc/kubernetes/pki/etcd/server.key \
      snapshot save /var/lib/etcd/snapshot-$(date +%F).db
nuc$ sudo ls -lh /var/lib/etcd/                         # il file è sul disco del NUC
nuc$ sudo etcdutl snapshot status /var/lib/etcd/snapshot-*.db -w table 2>/dev/null \
     || echo "etcdutl non installato: verifica dal Pod con 'etcdutl snapshot status'"
```

Poi **copialo fuori dal NUC**: un backup sullo stesso disco del dato originale non è un backup.
Automatizzalo con un CronJob o un timer systemd, e cifralo se non hai la cifratura a riposo.

**Ripristino (sintesi).** Si ferma il control plane spostando i manifest statici fuori da
`/etc/kubernetes/manifests`, si ripristina lo snapshot in una nuova directory dati con
`etcdutl snapshot restore <file> --data-dir /var/lib/etcd-restore`, si punta il manifest di etcd
alla nuova directory e si rimettono a posto i manifest. È un'operazione da provare almeno una
volta in laboratorio, con calma, prima di averne bisogno.

Una riflessione da professionista: con GitOps, **etcd non è più l'unica copia del tuo stato
desiderato**. La maggior parte degli oggetti si ricrea da Git. Lo snapshot resta indispensabile
per ciò che non sta in Git: stato generato a runtime, oggetti creati da controller, e il cluster
nel suo insieme quando serve un ripristino rapido.

## 14.3 Certificati

I certificati generati da kubeadm scadono dopo **un anno**. Se scadono, l'API server smette di
accettare connessioni e il cluster diventa inaccessibile: è uno dei guasti più comuni nei
cluster kubeadm dimenticati.

```bash
nuc$ sudo kubeadm certs check-expiration
```

`kubeadm upgrade apply` li rinnova automaticamente, quindi un cluster aggiornato regolarmente non
ha il problema. Altrimenti:

```bash
nuc$ sudo kubeadm certs renew all
nuc$ # riavvia i componenti del control plane: sposta e rimetti i manifest statici, oppure
nuc$ sudo crictl ps --name 'kube-apiserver|kube-controller-manager|kube-scheduler|etcd' -q | xargs -r sudo crictl stop
nuc$ sudo cp /etc/kubernetes/admin.conf ~/.kube/config     # il kubeconfig admin contiene un certificato rinnovato
```

Ricordati di riscaricare anche `~/.kube/config-nuc` sulla tua macchina. Il certificato del
kubelet invece si rinnova da solo (rotazione automatica abilitata di default da kubeadm).

Esistono altre scadenze da tenere d'occhio: la CA del lab di cert-manager (10 anni, per scelta),
i certificati dei listener del Gateway (li rinnova cert-manager, controlla con
`kubectl get certificate -A`), le chiavi di Sealed Secrets (rinnovo automatico ogni 30 giorni).

## 14.4 Disaster recovery: ricostruire tutto da zero

Questo è l'esercizio finale del corso, e la prova che ogni strato è davvero codice. Immagina che
il disco del NUC sia morto. Con il repository, il backup della chiave di Sealed Secrets e i
`terraform.tfvars`, l'ordine è:

1. **Sistema operativo**: reinstalla Ubuntu, stesso IP, stessa chiave SSH.
2. **Cluster**: `make cluster` (Ansible). Circa 10 minuti.
3. **Piattaforma**: `make platform` e `make platform-config` con `enable_gitops = false`. Lo
   stato di Terraform era sul disco perso? Nessun problema: su un cluster vuoto Terraform ricrea
   tutto da zero. (Nel cloud useremo uno stato remoto proprio per non dipendere da un disco.)
4. **Chiave di Sealed Secrets**: `kubectl apply -f sealed-secrets-master.key`. **Prima** di
   accendere GitOps: se il controller parte senza la chiave, ne genera una nuova e i SealedSecret
   non si decifrano.
5. **GitOps**: `enable_gitops = true`, `make platform-config`. Argo CD installa il controller di
   Sealed Secrets (che trova la chiave), Ollama, le applicazioni.
6. **Dati**: i volumi `local-path` (i modelli di Ollama) si riscaricano da soli con il Job
   PostSync. Dati applicativi veri richiederebbero un backup dei volumi (Velero, snapshot CSI).
7. **Fiducia e DNS**: la CA di cert-manager è nuova, quindi riesporta `lab-root-ca.crt` e
   reimportala nei client. (Esercizio 3: rendi la CA persistente.)
8. **Verifica**: `make smoke`.

Cronometralo. Un'ora scarsa per ricostruire da zero un cluster completo con piattaforma,
applicazioni, TLS e segreti è un risultato da raccontare con numeri precisi in un colloquio.

## 14.5 Metodo di troubleshooting

Il principio: segui il percorso della richiesta o dell'oggetto, **dall'esterno verso l'interno**
o **dall'alto verso il basso**, e fermati al primo punto che non torna. Non saltare a ipotesi.

**Un Pod non parte.** `kubectl get pod` e leggi la colonna STATUS, poi `kubectl describe pod`
e leggi gli Events in fondo.

- `Pending` — lo scheduler non trova un nodo: risorse insufficienti, taint, PVC non legato.
  Gli Events lo dicono esplicitamente.
- `ImagePullBackOff` / `ErrImagePull` — nome o tag sbagliato, registry privato senza credenziali,
  pacchetto GHCR ancora privato.
- `CrashLoopBackOff` — il container parte e muore. `kubectl logs <pod> --previous` mostra i log
  dell'esecuzione precedente, quella che è morta.
- `CreateContainerConfigError` — manca un ConfigMap o un Secret referenziato (senza `optional`).
- `OOMKilled` nel `lastState` — ha superato il limit di memoria. Alza il limit o riduci l'heap
  (`MaxRAMPercentage`).
- Violazione di Pod Security — il Pod non viene nemmeno creato: guarda gli eventi del
  **ReplicaSet** (`kubectl describe rs`), non del Pod.

**Il Pod è Running ma non riceve traffico.** Controlla nell'ordine: il Pod è `Ready`
(readiness probe)? Il Service ha endpoint (`kubectl get endpointslice -l
kubernetes.io/service-name=hello-backend`)? Il selector del Service corrisponde alle etichette
del Pod? La `targetPort` corrisponde alla porta del container? Una NetworkPolicy blocca il
flusso (prova da un Pod di debug, `k8s/learn/01-pod-debug.yaml`)?

**Dall'esterno non si raggiunge l'applicazione.** Percorso inverso: il nome risolve all'IP del
Gateway (`getent hosts hello.lab.home.arpa`)? L'IP risponde (`curl -v http://IP/`, ARP:
`ip neigh`)? Il Gateway è `Programmed` e la HTTPRoute `Accepted` e `ResolvedRefs`
(`kubectl describe httproute -n hello hello`)? Il certificato è pronto
(`kubectl get certificate -A`)? Il data plane NGINX ha log di errore
(`kubectl -n nginx-gateway logs deploy/<nome-del-data-plane>`)?

**Argo CD dice OutOfSync o Degraded.** `argocd app get hello` e `argocd app diff hello`. Degraded
significa che le risorse sono applicate ma non sane: il problema è quasi sempre in uno dei casi
precedenti.

**Il nodo ha problemi.** `kubectl describe node` (Conditions: MemoryPressure, DiskPressure),
`journalctl -u kubelet -e`, `journalctl -u containerd -e`, `crictl ps -a`. DiskPressure su un
NUC spesso significa immagini vecchie accumulate: il kubelet fa garbage collection, ma controlla
lo spazio con `df -h /var/lib/containerd`.

Strumenti che accelerano tutto questo: `k9s` (interfaccia testuale), `stern` (log di più Pod
insieme), `kubectl events --for pod/<nome>`, e k8sgpt del capitolo 12 come primo filtro.

## 14.6 Esercizi

1. Esegui un upgrade di patch (1.36.x → 1.36.y) seguendo la procedura, poi aggiorna Ansible.
2. Automatizza lo snapshot di etcd con un CronJob nel namespace `kube-system` che gira sul nodo
   control plane (`nodeSelector`, toleration, `hostPath` su `/var/lib/etcd` e `/etc/kubernetes/pki/etcd`),
   e mantieni solo gli ultimi 7 file.
3. Rendi persistente la CA del laboratorio: esportala una volta, sigillala come SealedSecret
   `lab-root-ca` in `cert-manager` e togli la sua generazione da Terraform. Così il DR non
   richiede di reimportare la CA nei client.
4. Fai il disaster recovery completo della sezione 14.4 e annota il tempo di ogni passo.

<!-- nav -->
---

[← Capitolo 13 — Osservabilità](13-osservabilita.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 15 — Verso il cloud: AWS, Google Cloud, Azure →](15-verso-il-cloud.md)
