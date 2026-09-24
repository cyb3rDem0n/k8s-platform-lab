# Capitolo 1 — Come funziona Kubernetes

Questo capitolo è solo teoria, ma è la teoria che userai in ogni capitolo successivo.
Rileggilo quando qualcosa non si comporta come ti aspetti: quasi sempre la risposta è qui.

## 1.1 Il problema che Kubernetes risolve

Hai dei container. Devi decidere su quale macchina farli girare, riavviarli quando muoiono,
aggiornarli senza interrompere il servizio, collegarli tra loro con nomi stabili anche se
cambiano IP, dargli configurazione e segreti, esporli all'esterno. Fatto a mano su una macchina
è gestibile; su cento macchine e mille container no.

Kubernetes risolve il problema con un'idea precisa: **tu descrivi lo stato desiderato, il
sistema lavora in continuazione per far coincidere lo stato reale con quello desiderato**. Non
dici "avvia tre container"; dici "voglio che esistano sempre tre repliche di questo Pod". Se un
nodo muore e ne restano due, nessuno deve intervenire: il sistema nota la differenza e ne crea
una terza.

## 1.2 Il ciclo di riconciliazione

Ogni componente attivo di Kubernetes è un **controller** che esegue lo stesso ciclo infinito:

```
      ┌──────────────────────────────────────────────┐
      │   1. osserva lo stato reale  (watch sull'API) │
      │   2. confrontalo con lo stato desiderato      │
      │   3. agisci per ridurre la differenza         │
      └──────────────────────┬───────────────────────┘
                             └──────── ripeti per sempre
```

Il ReplicaSet controller conta i Pod e ne crea o cancella. Il Deployment controller gestisce i
ReplicaSet durante un aggiornamento. Il kubelet su ogni nodo guarda i Pod assegnati al suo nodo
e avvia o ferma i container. MetalLB, cert-manager, Argo CD: sono tutti controller che seguono
lo stesso schema. Una volta capito il ciclo, hai capito come si estende Kubernetes.

Due conseguenze pratiche:

- I comandi sono **asincroni**. `kubectl apply` ritorna appena l'API server ha salvato l'oggetto,
  non quando i container sono partiti. Per questo esistono `kubectl rollout status` e `kubectl wait`.
- Le modifiche fatte "a mano" su un oggetto gestito da un controller vengono **annullate**. Se
  cancelli un Pod di un Deployment, ne rinasce uno. Se modifichi un oggetto che Argo CD gestisce
  con `selfHeal`, torna com'era. Non è un bug: è il modello.

## 1.3 L'architettura

```
 ┌──────────────────────────── CONTROL PLANE ─────────────────────────────┐
 │                                                                         │
 │   kube-apiserver  ◄──────►  etcd                                        │
 │     ▲   ▲   ▲               (database chiave-valore: TUTTO lo stato)    │
 │     │   │   └── kube-scheduler        (decide su quale nodo va un Pod)  │
 │     │   └────── kube-controller-manager (i controller "di serie")       │
 │     │                                                                   │
 └─────┼───────────────────────────────────────────────────────────────────┘
       │ HTTPS (6443)
 ┌─────┼──────────────────────────── NODO ─────────────────────────────────┐
 │     ▼                                                                    │
 │   kubelet ──CRI──► containerd ──► runc ──► container                     │
 │   kube-proxy (regole nftables/iptables per i Service)                    │
 │   CNI plugin (Calico: IP ai Pod, routing, NetworkPolicy)                 │
 └──────────────────────────────────────────────────────────────────────────┘
```

**kube-apiserver** è l'unico componente che parla con etcd. Tutti gli altri, inclusi i tuoi
comandi `kubectl`, passano dall'API server. Ogni richiesta attraversa tre fasi: autenticazione
(chi sei: certificato client, token), autorizzazione (cosa puoi fare: RBAC), admission control
(la richiesta è accettabile: Pod Security Admission, quote, webhook). Solo dopo l'oggetto viene
salvato.

**etcd** è un database chiave‑valore distribuito basato sul protocollo di consenso Raft. Contiene
lo stato dell'intero cluster. Perdere etcd senza backup significa perdere il cluster: per
questo nel capitolo 14 impareremo a farne lo snapshot. In produzione si usano 3 o 5 membri per
tollerare guasti; noi ne abbiamo uno.

**kube-scheduler** osserva i Pod senza nodo assegnato e sceglie un nodo in due fasi: filtra i
nodi che non possono ospitare il Pod (risorse insufficienti, taint, affinità), poi assegna un
punteggio ai rimanenti. Scrive la decisione nel campo `spec.nodeName`. Non avvia nulla.

**kube-controller-manager** contiene i controller di base: Deployment, ReplicaSet, Job,
EndpointSlice, Node, ServiceAccount e molti altri, compilati in un unico processo.

**kubelet** è l'agente su ogni nodo. Riceve i Pod assegnati al suo nodo, chiede al runtime di
avviare i container tramite la **CRI** (Container Runtime Interface, un'API gRPC), esegue le
probe, riporta lo stato. Non è un Pod: è un servizio systemd.

**containerd** è il runtime: scarica le immagini, prepara i filesystem e delega l'esecuzione
vera e propria a **runc**, che usa le primitive del kernel Linux (namespace per l'isolamento,
cgroup per i limiti di risorse). Docker non è più coinvolto da Kubernetes 1.24: le immagini
costruite con Docker funzionano identiche perché seguono lo standard OCI.

**kube-proxy** implementa i Service: traduce "l'IP virtuale del Service" in "uno degli IP dei
Pod dietro" programmando regole nel kernel (nel nostro cluster con nftables).

**Il plugin CNI** (Container Network Interface) dà un IP a ogni Pod e garantisce che ogni Pod
possa raggiungere ogni altro Pod senza NAT. Kubernetes definisce il requisito, non
l'implementazione. Noi usiamo **Calico** perché, a differenza di Flannel, implementa le
NetworkPolicy: senza un CNI che le applica, le NetworkPolicy vengono accettate dall'API server e
poi ignorate, in silenzio.

## 1.4 Gli oggetti fondamentali

**Pod.** La più piccola unità schedulabile. Uno o più container che condividono namespace di
rete (stesso IP, si parlano su `localhost`) e possono condividere volumi. Il Pod è effimero:
quando muore non "risorge", ne viene creato uno nuovo con un nuovo IP. Non si creano quasi mai
Pod direttamente.

**ReplicaSet.** Garantisce che esista un certo numero di Pod identici. Non lo usi direttamente.

**Deployment.** Gestisce i ReplicaSet per fare aggiornamenti progressivi (rolling update) e
rollback. È l'oggetto giusto per applicazioni stateless come il nostro backend.

**Service.** Un nome DNS e un IP virtuale stabili davanti a un insieme di Pod scelti tramite
**label selector**. I tipi: `ClusterIP` (solo interno), `NodePort` (una porta su ogni nodo),
`LoadBalancer` (un IP esterno dedicato, fornito da un'implementazione esterna).

**EndpointSlice.** L'elenco concreto degli IP dei Pod pronti dietro un Service. Il controller lo
aggiorna quando i Pod passano la readiness probe. È qui che guardare quando un Service "non
risponde".

**ConfigMap e Secret.** Configurazione e dati sensibili, iniettati come variabili d'ambiente o
file. Attenzione: un Secret è codificato in base64, **non cifrato**. Il capitolo 11 è dedicato a
questo problema.

**Namespace.** Uno spazio di nomi per raggruppare risorse, applicare quote, policy e permessi.

**Custom Resource Definition (CRD).** Estende l'API con nuovi tipi. `Gateway`, `HTTPRoute`,
`Certificate`, `Application`, `SealedSecret` sono tutti tipi aggiunti da CRD, e ognuno ha un
controller che li riconcilia. Questa estensibilità rende Kubernetes una piattaforma per
costruire piattaforme.

## 1.5 Label, selector e il collegamento tra oggetti

Kubernetes non collega gli oggetti con riferimenti rigidi, ma con **etichette**. Un Service non
"contiene" dei Pod: seleziona tutti i Pod che hanno le etichette indicate, in qualunque momento.

```yaml
# Service                                 # Pod (creato dal Deployment)
spec:                                     metadata:
  selector:                                 labels:
    app.kubernetes.io/name: hello-backend     app.kubernetes.io/name: hello-backend
```

È un accoppiamento debole e potentissimo, ma anche la causa del bug più comune dei principianti:
un errore di battitura nel selector produce un Service con zero endpoint e nessun errore esplicito.

Usiamo le etichette raccomandate `app.kubernetes.io/*` (name, component, part-of, version):
strumenti come Argo CD, Grafana e k8sgpt le riconoscono.

## 1.6 Riepilogo del capitolo

Lo stato desiderato vive in etcd, lo scrivi attraverso l'API server, i controller lo rendono
reale con cicli di riconciliazione. Il kubelet esegue i Pod tramite containerd, kube-proxy e il
CNI fanno funzionare la rete. Gli oggetti si collegano tramite etichette. Le CRD estendono
l'API con nuovi tipi e nuovi controller.

<!-- nav -->
---

[← Capitolo 0 — Come usare questo tutorial](00-come-usare-il-tutorial.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 2 — Installare il cluster a mano con kubeadm →](02-cluster-con-kubeadm.md)
