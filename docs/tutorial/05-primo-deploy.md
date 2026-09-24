# Capitolo 5 — Il primo deploy

## 5.1 Cosa applichiamo

L'applicazione in `k8s/apps/hello/base` è divisa in tre strati, ciascuno applicabile da solo:

```
base/
├── core/       Namespace, ServiceAccount, ConfigMap, 2 Deployment, 2 Service, HPA, PDB
├── network/    NetworkPolicy (capitolo 7)
└── routing/    HTTPRoute del Gateway API (capitolo 6)
```

In questo capitolo applichiamo solo `core`, tramite `k8s/learn/stage-05-core`, un piccolo
overlay Kustomize che aggiunge i tag immagine corretti.

**Kustomize** è integrato in kubectl (`kubectl apply -k`). Lavora per **composizione e patch**:
una base di manifest YAML normali, e overlay che la riusano modificandone alcuni campi (tag
immagine, repliche, variabili). Non ci sono template né linguaggi: l'output è YAML valido e
leggibile. Prima di applicare, guarda sempre cosa verrà applicato:

```bash
pc$ kubectl kustomize k8s/learn/stage-05-core | less
pc$ kubectl apply -k k8s/learn/stage-05-core
pc$ kubectl -n hello get all
pc$ kubectl -n hello rollout status deploy/hello-backend
```

## 5.2 Il Namespace e Pod Security Admission

```yaml
labels:
  pod-security.kubernetes.io/enforce: restricted
```

**Pod Security Admission** è il controllore di ammissione integrato che valuta ogni Pod rispetto
a tre profili standard: `privileged` (nessun vincolo), `baseline` (vieta le escalation note:
hostNetwork, container privilegiati, hostPath...), `restricted` (in più: utente non root,
nessuna capability, seccomp attivo, niente privilege escalation). Le modalità: `enforce`
rifiuta i Pod non conformi, `warn` mostra un avviso a chi li crea, `audit` li annota nel log di
audit.

Con `restricted` in `enforce`, un Deployment che dimentichi `runAsNonRoot` non riuscirà a creare
Pod: il ReplicaSet mostrerà l'errore negli eventi. Provalo: è istruttivo vedere dove compare
l'errore (non sul Deployment, ma sul ReplicaSet).

## 5.3 Il Deployment del backend, campo per campo

Apri `k8s/apps/hello/base/core/backend-deployment.yaml` e seguilo.

**`selector.matchLabels`** — quali Pod appartengono al Deployment. È **immutabile** dopo la
creazione: sceglilo con cura. Deve corrispondere alle etichette del `template`.

**`replicas: 2`** — due repliche anche su un nodo solo: così un rolling update, o il crash di un
Pod, non lasciano il servizio scoperto.

**`strategy.rollingUpdate`** — `maxSurge: 1, maxUnavailable: 0`: durante un aggiornamento
Kubernetes crea prima un Pod nuovo, attende che sia pronto, poi elimina un Pod vecchio. Non
scende mai sotto il numero desiderato. Costa un po' di risorse in più durante il rollout, in
cambio di zero downtime.

**`revisionHistoryLimit: 5`** — quanti ReplicaSet vecchi conservare per i rollback.

**`serviceAccountName` e `automountServiceAccountToken: false`** — ogni Pod ha un'identità verso
l'API server. Il nostro backend non parla con l'API server, quindi non montiamo il token: un
token in meno da rubare.

**`terminationGracePeriodSeconds: 30`** — vedi 4.3.

**`securityContext` del Pod** — `runAsNonRoot`, utente e gruppo 65532, `fsGroup` (proprietario
dei volumi montati), `seccompProfile: RuntimeDefault` (filtro delle system call del runtime:
blocca chiamate pericolose e rare).

**`securityContext` del container** — `allowPrivilegeEscalation: false` (niente setuid),
`readOnlyRootFilesystem: true` (un attaccante non può modificare i binari), `capabilities.drop:
[ALL]`. Siccome il filesystem è in sola lettura, montiamo un `emptyDir` su `/tmp`, che la JVM
usa per file temporanei. `sizeLimit` impedisce che riempia il disco del nodo.

**`envFrom.configMapRef`** — tutte le chiavi della ConfigMap diventano variabili d'ambiente.

**`env.valueFrom.secretKeyRef` con `optional: true`** — il token arriva da un Secret. Con
`optional: true` il Pod parte anche se il Secret non esiste: `/api/ask` risponderà 503. Senza
`optional`, il Pod resterebbe in `CreateContainerConfigError`. Abbiamo scelto la degradazione
controllata.

**Le probe** — vedi 4.4. La startupProbe concede fino a 60 s (`30 × 2 s`); la readiness è più
frequente (5 s) della liveness (10 s) perché deve reagire in fretta, mentre un riavvio ingiusto
costa molto di più di un ritardo nel rilevare un blocco.

**`topologySpreadConstraints`** — su più nodi distribuirebbe le repliche; su uno è ininfluente
ma è pronto per il futuro. `whenUnsatisfiable: ScheduleAnyway` lo rende una preferenza, non un
vincolo.

## 5.4 Risorse, QoS e perché niente limit di CPU

```yaml
resources:
  requests: { cpu: 50m, memory: 128Mi }
  limits:   { memory: 256Mi }
```

Le **requests** sono una prenotazione: lo scheduler mette un Pod su un nodo solo se la somma
delle requests ci sta. Sono anche il peso relativo con cui il kernel divide la CPU quando c'è
contesa. I **limits** sono un tetto imposto dal kernel, e i due tetti si comportano in modo
molto diverso:

- superare il **limite di memoria** causa la terminazione del container (OOMKilled): la memoria
  non si può "rallentare";
- superare il **limite di CPU** causa **throttling**: il processo viene sospeso fino al periodo
  successivo del CFS (100 ms). Una JVM con garbage collector multi-thread può esaurire la quota
  in pochi millisecondi e restare ferma il resto del periodo: picchi di latenza anche con il nodo
  quasi scarico.

Per questo impostiamo sempre il limite di memoria (protegge il nodo) ma non quello di CPU: le
requests garantiscono la quota minima, e se il nodo ha CPU libera il Pod la usa. È una posizione
diffusa ma non universale: in ambienti multi-tenant con quote rigide i limiti di CPU possono
essere obbligatori (`LimitRange`). Conosci entrambe le posizioni e le loro ragioni.

La combinazione determina la **classe QoS** del Pod, che decide l'ordine di sfratto quando il
nodo è sotto pressione di memoria:

- **Guaranteed** — requests uguali ai limits per CPU e memoria in tutti i container: sfrattato per ultimo;
- **Burstable** — almeno una request o un limit, ma non Guaranteed: il nostro caso;
- **BestEffort** — nessuna request né limit: sfrattato per primo.

```bash
pc$ kubectl -n hello get pod -l app.kubernetes.io/name=hello-backend \
      -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass
```

## 5.5 Il Service e gli EndpointSlice

```bash
pc$ kubectl -n hello get svc hello-backend
pc$ kubectl -n hello get endpointslices -l kubernetes.io/service-name=hello-backend -o wide
```

Negli EndpointSlice vedi gli IP dei Pod e, per ciascuno, `ready: true/false`. Quando un Service
"non funziona", questo è il primo posto dove guardare: zero endpoint significa selector
sbagliato o readiness che fallisce.

Il DNS del cluster (CoreDNS) risolve `hello-backend` (dallo stesso namespace),
`hello-backend.hello` e il nome completo `hello-backend.hello.svc.cluster.local`. Nota che la
`targetPort` del Service è `http`, il **nome** della porta del container: se un giorno il
container ascoltasse su 9090, basterebbe cambiare il Deployment.

## 5.6 Primo accesso: port-forward

```bash
pc$ kubectl -n hello port-forward svc/hello-frontend 8080:80
# un altro terminale, o il browser su http://localhost:8080
pc$ curl -s localhost:8080/api/hello
```

`port-forward` crea un tunnel dalla tua macchina all'API server, dall'API server al kubelet, dal
kubelet al Pod. È perfetto per il debug e totalmente inadatto a servire utenti: passa da un
singolo Pod scelto all'avvio, dipende dalla tua sessione e dal tuo kubeconfig. Il capitolo 6 è
dedicato ai modi seri di esporre un servizio.

Qui la richiesta `/api/hello` entra nel frontend nginx, che fa da reverse proxy verso il Service
`hello-backend`. Richiamala più volte: il campo `pod` cambia, perché kube-proxy distribuisce le
connessioni tra i due Pod del backend.

## 5.7 Il primo Secret, fatto nel modo "sbagliato"

```bash
pc$ kubectl -n hello create secret generic hello-backend-secret \
      --from-literal=API_TOKEN="$(openssl rand -hex 24)"
pc$ kubectl -n hello rollout restart deploy/hello-backend
pc$ curl -s localhost:8080/api/info      # "apiTokenConfigured": true
```

Due lezioni in questo passaggio. Le variabili d'ambiente sono lette **all'avvio del processo**:
cambiare un Secret o una ConfigMap non aggiorna i Pod già in esecuzione, serve un riavvio
(`rollout restart` lo fa in modo progressivo, senza downtime). E questo Secret esiste solo nel
cluster: non è in Git, nessuno sa come ricrearlo, e chiunque possa leggere i Secret del namespace
vede il token in chiaro:

```bash
pc$ kubectl -n hello get secret hello-backend-secret -o jsonpath='{.data.API_TOKEN}' | base64 -d
```

Il capitolo 11 risolve entrambi i problemi.

## 5.8 Aggiornamenti e rollback

Cambia il saluto e osserva il rollout:

```bash
pc$ kubectl -n hello patch configmap hello-backend-config \
      -p '{"data":{"GREETING":"Aggiornato a mano: non farlo in produzione"}}'
pc$ kubectl -n hello rollout restart deploy/hello-backend
pc$ kubectl -n hello get pods -l app.kubernetes.io/name=hello-backend -w
```

Vedrai un Pod nuovo diventare `1/1 Running` prima che uno vecchio passi a `Terminating`: è
`maxUnavailable: 0` in azione.

```bash
pc$ kubectl -n hello rollout history deploy/hello-backend
pc$ kubectl -n hello rollout undo deploy/hello-backend               # torna alla revisione precedente
pc$ kubectl -n hello rollout undo deploy/hello-backend --to-revision=1
```

Attenzione a una sottigliezza: `rollout undo` ripristina il **template del Pod**, non la
ConfigMap. Il saluto modificato resta, perché la ConfigMap non è versionata dal Deployment.
Soluzione professionale: il `configMapGenerator` di Kustomize genera ConfigMap con un suffisso
hash del contenuto (`hello-backend-config-7g9f2k`); cambiare un valore cambia il nome, cambia il
template del Deployment e innesca automaticamente un rollout, con rollback coerenti. È il primo
esercizio del capitolo.

Hai anche appena creato **drift**: lo stato del cluster non corrisponde più a nessun file.
Ricordatelo; nel capitolo 10 Argo CD renderà questo tipo di modifica impossibile da dimenticare.

## 5.9 La cassetta degli attrezzi del debugging

Il flusso da seguire quando qualcosa non funziona, dall'alto verso il basso:

```bash
pc$ kubectl -n hello get pods -o wide                       # STATUS, RESTARTS, nodo, IP
pc$ kubectl -n hello describe pod <pod>                     # eventi in fondo: la risposta è spesso lì
pc$ kubectl -n hello get events --sort-by=.lastTimestamp    # cronologia del namespace
pc$ kubectl -n hello logs <pod>                             # log correnti
pc$ kubectl -n hello logs <pod> --previous                  # log del container PRIMA del crash
pc$ kubectl -n hello logs -l app.kubernetes.io/name=hello-backend --prefix -f   # tutte le repliche
```

Per entrare in un container distroless, che non ha shell, si usa un **container effimero**
agganciato al Pod. `--target` gli fa condividere il namespace dei processi del container
indicato; `--profile=restricted` lo rende conforme al Pod Security del namespace:

```bash
pc$ kubectl -n hello debug -it <pod-backend> --image=busybox:1.37 --target=backend --profile=restricted -- sh
/ $ ps                                  # vedi il processo java
/ $ wget -qO- localhost:8080/healthz/ready
```

Gli stati più comuni e le loro cause:

- **ImagePullBackOff / ErrImagePull** — tag inesistente, immagine privata senza pull secret,
  nome del registry sbagliato. `describe pod` riporta il messaggio del registry.
- **CrashLoopBackOff** — il processo termina subito. `logs --previous`. Spesso configurazione
  mancante o errata.
- **CreateContainerConfigError** — manca una ConfigMap o un Secret referenziati (senza
  `optional: true`).
- **Pending** — lo scheduler non trova un nodo: requests troppo alte, PVC non collegabile, taint.
  `describe pod` mostra il motivo nell'evento `FailedScheduling`.
- **Running ma 0/1 Ready** — la readiness fallisce: guarda gli eventi `Unhealthy` e verifica
  l'endpoint della probe con un container effimero.
- **OOMKilled** (in `lastState`) — limite di memoria superato: alza il limite o riduci l'heap.

## 5.10 Esercizi

1. Sostituisci la ConfigMap con un `configMapGenerator` nello stage 05, cambia il saluto e
   verifica che il rollout parta da solo e che `rollout undo` ripristini anche il saluto.
2. Rompi volontariamente la readiness (`kubectl set env deploy/hello-backend PORT=9999`) e
   osserva, nell'ordine: probe che falliscono, EndpointSlice che si svuota, rollout che si ferma
   senza uccidere i Pod vecchi. Poi `rollout undo`.
3. Imposta il limite di memoria a `64Mi` e osserva l'OOMKill. Spiega perché con
   `MaxRAMPercentage=75` l'heap diventa di circa 48 Mi e cosa succede fuori dall'heap.

<!-- nav -->
---

[← Capitolo 4 — Un backend Java pensato per Kubernetes](04-backend-java.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 5B — Helm: il package manager di Kubernetes →](05b-helm.md)
