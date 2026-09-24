# Capitolo 2 — Installare il cluster a mano con kubeadm

**kubeadm** è lo strumento ufficiale per creare cluster Kubernetes conformi. Non gestisce il
sistema operativo né installa pacchetti: prende una macchina preparata e ci costruisce sopra un
control plane. È quello che usano, sotto il cofano, molti installer più sofisticati.

In questo capitolo prepari il NUC comando per comando. Nel capitolo 3 automatizzerai tutto.

## 2.1 Preparare il sistema operativo

**Swap.** Il kubelet, per impostazione predefinita, rifiuta di partire con lo swap attivo.

*Perché:* lo scheduler assegna i Pod ai nodi in base alle `requests` di memoria, assumendo che
la memoria sia RAM reale con prestazioni prevedibili. Con lo swap, un Pod che supera la RAM
rallenterebbe invece di essere terminato, e le garanzie di qualità del servizio salterebbero.
Il supporto allo swap esiste (NodeSwap), ma richiede configurazione esplicita: per ora lo
disattiviamo.

```bash
nuc$ sudo swapoff -a
nuc$ sudo sed -i.bak '/\sswap\s/ s/^\([^#]\)/# \1/' /etc/fstab   # permanente
```

**Moduli del kernel.** `overlay` serve a containerd per il filesystem stratificato delle
immagini. `br_netfilter` fa sì che il traffico che passa sui bridge Linux attraversi netfilter,
dove kube-proxy e il CNI hanno scritto le loro regole.

```bash
nuc$ printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/k8s.conf
nuc$ sudo modprobe overlay && sudo modprobe br_netfilter
```

**sysctl.** Abilitiamo l'inoltro dei pacchetti IP (il nodo deve fare da router per i Pod) e il
passaggio del traffico dei bridge attraverso le regole del firewall.

```bash
nuc$ sudo tee /etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
nuc$ sudo sysctl --system
```

**Verifica:**

```bash
nuc$ lsmod | grep -E 'overlay|br_netfilter'      # entrambi presenti
nuc$ sysctl net.ipv4.ip_forward                  # = 1
nuc$ free -h | grep -i swap                      # Swap: 0B
```

## 2.2 Installare containerd

Ubuntu 24.04 fornisce containerd 1.7 nei suoi repository, ma le minor recenti di Kubernetes
richiedono containerd 2.x. Usiamo il pacchetto `containerd.io` del repository di Docker (solo
containerd, non Docker Engine).

```bash
nuc$ sudo install -m 0755 -d /etc/apt/keyrings
nuc$ sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
nuc$ echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo $VERSION_CODENAME) stable" \
     | sudo tee /etc/apt/sources.list.d/docker.list
nuc$ sudo apt-get update && sudo apt-get install -y containerd.io
```

Il pacchetto arriva configurato per Docker, con il plugin CRI **disabilitato**. Rigeneriamo la
configurazione di default e attiviamo il driver cgroup di systemd:

```bash
nuc$ containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
nuc$ sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
nuc$ sudo systemctl restart containerd && sudo systemctl enable containerd
```

*Perché il driver cgroup conta:* i cgroup sono la struttura del kernel che limita CPU e memoria
dei processi. Su un sistema con systemd, systemd gestisce l'albero dei cgroup. Se kubelet e
containerd usassero il driver `cgroupfs`, ci sarebbero due gestori indipendenti dello stesso
albero, con instabilità sotto pressione di memoria. Regola: kubelet e runtime devono usare lo
stesso driver, e su systemd quel driver è `systemd`.

**Verifica:**

```bash
nuc$ sudo ctr version                                       # client e server 2.x
nuc$ grep -n 'SystemdCgroup' /etc/containerd/config.toml    # = true
```

## 2.3 Installare kubeadm, kubelet e kubectl

I pacchetti ufficiali stanno su `pkgs.k8s.io`, con **un repository per ogni minor**. Cambiare
minor richiede di cambiare repository: è voluto, perché gli upgrade di minor devono essere
un'azione esplicita.

```bash
nuc$ K8S_MINOR=v1.36
nuc$ curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key \
     | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
nuc$ echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
     | sudo tee /etc/apt/sources.list.d/kubernetes.list
nuc$ sudo apt-get update && sudo apt-get install -y kubelet kubeadm kubectl
nuc$ sudo apt-mark hold kubelet kubeadm kubectl
```

`apt-mark hold` impedisce che un `apt upgrade` distratto aggiorni i componenti del cluster
fuori dalla procedura corretta.

*Perché v1.36 e non l'ultima:* a settembre 2026 l'ultima minor è la 1.37, uscita ad agosto.
Usare la penultima (N‑1) è una prassi diffusa: ha già ricevuto diverse patch di stabilità, gli
strumenti dell'ecosistema la supportano tutti, e resta in supporto a lungo. Kubernetes mantiene
le ultime tre minor, e ciascuna riceve patch per circa quattordici mesi.

Il kubelet ora va in crash-loop ogni pochi secondi (`systemctl status kubelet`): aspetta una
configurazione che kubeadm non ha ancora scritto. È normale.

## 2.4 Il file di configurazione di kubeadm

Si può passare tutto a `kubeadm init` con dei flag, ma un file di configurazione è versionabile,
revisionabile e ripetibile. Creiamo `/etc/kubernetes/kubeadm-config.yaml`:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.1.50        # IP del NUC
  bindPort: 6443
nodeRegistration:
  name: nuc
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.36.4              # l'output di: kubeadm version -o short
clusterName: k8s-platform-lab
controlPlaneEndpoint: 192.168.1.50:6443
networking:
  podSubnet: 10.244.0.0/16              # rete dei Pod: la configureremo identica in Calico
  serviceSubnet: 10.96.0.0/12           # rete degli IP virtuali dei Service
apiServer:
  certSANs: ["192.168.1.50", "nuc"]
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: nftables
```

Qualche scelta da capire:

- `podSubnet` e `serviceSubnet` non devono sovrapporsi tra loro né con la tua LAN. Se la tua
  LAN fosse `10.244.x.x`, cambia la rete dei Pod.
- `controlPlaneEndpoint` è l'indirizzo stabile dell'API server. Con un solo nodo coincide con
  il suo IP; con più control plane diventerebbe un IP virtuale o un nome DNS davanti a tutti.
  Impostarlo da subito rende possibile aggiungere control plane in futuro senza ricostruire.
- `certSANs` aggiunge nomi e IP al certificato dell'API server: così `kubectl` può connettersi
  anche usando il nome host.
- `mode: nftables` usa il backend moderno di kube-proxy. `iptables` resta il fallback compatibile.

## 2.5 kubeadm init: cosa succede davvero

```bash
nuc$ sudo kubeadm init --config /etc/kubernetes/kubeadm-config.yaml --upload-certs
```

kubeadm procede per **fasi**, ognuna eseguibile anche singolarmente con `kubeadm init phase`:

1. **preflight** — controlla swap, porte libere, runtime raggiungibile, moduli; scarica le immagini.
2. **certs** — crea una PKI completa in `/etc/kubernetes/pki`: una CA del cluster, una per etcd,
   una per il front-proxy, e i certificati di tutti i componenti. Le CA durano 10 anni, gli altri
   certificati 1 anno (li rinnoveremo nel capitolo 14).
3. **kubeconfig** — genera i file con cui i componenti si autenticano all'API server
   (`admin.conf`, `super-admin.conf`, `controller-manager.conf`, `scheduler.conf`, `kubelet.conf`).
4. **etcd** e **control-plane** — scrive i manifest dei **static Pod** in `/etc/kubernetes/manifests`.
   Il kubelet sorveglia quella directory e avvia i Pod che trova, senza bisogno dell'API server.
   È così che si risolve il problema dell'uovo e della gallina: il control plane gira come Pod,
   ma sono Pod avviati dal kubelet leggendo file dal disco.
5. **kubelet-start** — scrive la configurazione del kubelet e lo riavvia (fine del crash-loop).
6. **wait-control-plane** — attende che l'API server risponda.
7. **upload-config** e **upload-certs** — salva la configurazione nel cluster (ConfigMap) e, con
   `--upload-certs`, i certificati cifrati per permettere l'aggiunta di altri control plane.
8. **mark-control-plane** — etichetta il nodo e aggiunge il taint
   `node-role.kubernetes.io/control-plane:NoSchedule`.
9. **bootstrap-token** — crea il token con cui altri nodi potranno unirsi (`kubeadm join`).
10. **addon** — installa CoreDNS e kube-proxy.

Alla fine stampa i comandi per configurare `kubectl` e per aggiungere nodi. Configura kubectl
per il tuo utente:

```bash
nuc$ mkdir -p $HOME/.kube
nuc$ sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
nuc$ sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**Verifica:**

```bash
nuc$ kubectl get nodes
NAME   STATUS     ROLES           AGE   VERSION
nuc    NotReady   control-plane   1m    v1.36.x
nuc$ kubectl -n kube-system get pods
# etcd, kube-apiserver, kube-controller-manager, kube-scheduler, kube-proxy: Running
# coredns: Pending
```

`NotReady` e CoreDNS in `Pending` sono corretti: manca la rete dei Pod. Il kubelet segnala il
nodo come non pronto finché nessun plugin CNI è configurato.

## 2.6 Installare Calico

Calico si installa tramite un operatore (tigera-operator): un controller che riceve una risorsa
`Installation` e crea tutto il resto. È lo stesso schema del capitolo 1, applicato alla rete.

```bash
nuc$ CALICO=v3.32.2
nuc$ kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO}/manifests/tigera-operator.yaml
nuc$ kubectl apply -f - <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: 10.244.0.0/16          # DEVE coincidere con podSubnet di kubeadm
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
```

- `blockSize: 26` — Calico assegna a ogni nodo blocchi di 64 indirizzi alla volta.
- `VXLANCrossSubnet` — tra nodi della stessa subnet instrada direttamente; tra subnet diverse
  incapsula in VXLAN. È il compromesso migliore per reti domestiche e cloud.
- `natOutgoing` — il traffico dai Pod verso l'esterno esce con l'IP del nodo.

```bash
nuc$ watch kubectl get pods -n calico-system       # attendi tutti Running
nuc$ kubectl get nodes                             # ora Ready
```

## 2.7 Un solo nodo: togliere il taint

Il control plane ha un taint che impedisce ai Pod normali di esservi schedulati: in produzione
il control plane va protetto dai carichi applicativi. Sul nostro unico nodo, però, senza
togliere il taint nessuna applicazione partirebbe.

```bash
nuc$ kubectl taint nodes nuc node-role.kubernetes.io/control-plane:NoSchedule-
```

Il `-` finale significa "rimuovi".

## 2.8 Accesso dalla tua macchina

```bash
pc$ scp giuseppe@192.168.1.50:.kube/config ~/.kube/config-nuc
pc$ export KUBECONFIG=~/.kube/config-nuc
pc$ kubectl get nodes -o wide
```

Tieni il kubeconfig del lab separato da quelli di lavoro: un `KUBECONFIG` esplicito evita di
lanciare un comando sul cluster sbagliato. Strumenti come `kubectx` o `kube-ps1` aiutano a
vedere sempre dove sei.

## 2.9 Test di fumo del cluster

```bash
pc$ kubectl create deployment smoke --image=nginxinc/nginx-unprivileged:1.29-alpine --replicas=2
pc$ kubectl expose deployment smoke --port=80 --target-port=8080
pc$ kubectl run -it --rm probe --image=curlimages/curl:8.20.0 --restart=Never -- curl -s smoke
pc$ kubectl delete deployment,service smoke
```

Se vedi l'HTML di nginx, funzionano insieme scheduler, kubelet, containerd, CNI, CoreDNS e
kube-proxy. È il test più economico che esista.

## 2.10 Troubleshooting dell'installazione

- **Il nodo resta NotReady:** `kubectl describe node nuc` e guarda le Conditions; spesso il CNI
  non è partito. `kubectl -n calico-system get pods`, poi `logs` del Pod in errore. Verifica che
  il `cidr` di Calico coincida con `podSubnet`.
- **kubeadm init fallisce al preflight:** leggi il messaggio, è quasi sempre esplicito (swap,
  porta 6443 occupata, containerd non raggiungibile). `sudo journalctl -u containerd`.
- **L'API server si riavvia in continuazione:** `sudo crictl ps -a` mostra i container anche
  senza API server; `sudo crictl logs <id>`. Causa frequente: driver cgroup non coerente.
- **Ricominciare da zero:** `sudo kubeadm reset -f`, poi rimuovi `/etc/cni/net.d` e `~/.kube`.
  Il playbook `ansible/reset.yml` fa esattamente questo.

<!-- nav -->
---

[← Capitolo 1 — Come funziona Kubernetes](01-come-funziona-kubernetes.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 3 — Automatizzare il nodo con Ansible →](03-automazione-con-ansible.md)
