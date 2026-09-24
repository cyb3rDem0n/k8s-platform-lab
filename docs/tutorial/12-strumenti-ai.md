# Capitolo 12 — Strumenti AI nel cluster e attorno al cluster

L'intelligenza artificiale entra in una piattaforma Kubernetes in tre modi diversi, con problemi
diversi, e conviene tenerli separati:

1. **L'AI come carico di lavoro** — un modello che gira nel cluster e serve le applicazioni.
   Problemi: risorse, storage dei modelli, latenza, isolamento di rete.
2. **L'AI come strumento di diagnosi** — un assistente che legge lo stato del cluster e spiega i
   problemi. Problemi: quali dati escono dal cluster, qualità delle risposte.
3. **L'AI come agente operativo** — un assistente che esegue comandi sul cluster. Problemi:
   permessi, errori distruttivi, prompt injection.

In questo capitolo li affrontiamo tutti e tre, nell'ordine, con un modello **locale**: nessun
dato del cluster esce dalla tua rete.

## 12.1 Un LLM nel cluster con Ollama

**Ollama** esegue modelli linguistici aperti (Llama, Qwen, Mistral, Gemma...) esponendo una API
REST semplice. Su CPU, senza GPU, i modelli piccoli (1–3 miliardi di parametri, quantizzati a
4 bit) sono utilizzabili: pochi token al secondo, abbastanza per una demo e per k8sgpt.

Il manifest è in `k8s/apps/ai/ollama/`. Le scelte:

- **PersistentVolumeClaim da 15 GiB** su `local-path`. Un modello pesa da 1 a diversi GB:
  riscaricarlo a ogni riavvio del Pod sarebbe lento e sprecherebbe banda. `local-path` crea una
  directory sul disco del NUC: nessuna replica, nessuna alta disponibilità, perfetto per un lab.
- **`strategy: Recreate`**. Il volume è `ReadWriteOnce`: un solo Pod alla volta può montarlo.
  Con un rolling update il nuovo Pod resterebbe bloccato in attesa del volume ancora montato dal
  vecchio. Recreate prima spegne, poi accende: qualche secondo di indisponibilità, accettabile.
- **Risorse**: request di 1 CPU e 3 GiB, limit di memoria a 6 GiB. Il modello caricato vive in
  RAM; `OLLAMA_KEEP_ALIVE=30m` lo tiene caricato mezz'ora dopo l'ultima richiesta.
  `OLLAMA_NUM_PARALLEL=1` evita che due richieste contemporanee si contendano i core.
- **Service ClusterIP**: l'LLM non è esposto fuori dal cluster. E la NetworkPolicy
  `ollama-ingress` accetta connessioni solo dal backend, dal Job di download e dall'eventuale
  operatore k8sgpt. Un modello raggiungibile da chiunque in rete è una risorsa di calcolo gratuita
  per chiunque la trovi.
- **Namespace `baseline`**: l'immagine ufficiale gira come root e scrive in `/root/.ollama`,
  quindi non passa il profilo `restricted`. È un compromesso esplicito e documentato;
  l'esercizio 1 ti chiede di eliminarlo.

**Il download del modello** è un `Job` con l'annotazione `argocd.argoproj.io/hook: PostSync`:
Argo CD lo esegue dopo ogni sincronizzazione riuscita. Chiama `POST /api/pull` di Ollama; se il
modello c'è già la chiamata ritorna subito, quindi è idempotente.
`hook-delete-policy: BeforeHookCreation` cancella il Job precedente prima di crearne uno nuovo.

```bash
pc$ kubectl -n ai get pods,pvc
pc$ kubectl -n ai logs job/ollama-pull-model          # {"status":"success"} al termine
pc$ kubectl -n ai port-forward svc/ollama 11434:11434 &
pc$ curl -s localhost:11434/api/tags | jq '.models[].name'
```

**Scegliere il modello.** `qwen2.5:1.5b` (circa 1 GB) è il default perché risponde in pochi
secondi su CPU e parla italiano in modo dignitoso. Con 16 GB di RAM puoi provare modelli da
3 miliardi di parametri. Il nome del modello compare in due punti che devono coincidere:
`OLLAMA_MODEL` nel ConfigMap del backend e il body del Job di pull. È un'ottima occasione per
un esercizio su Kustomize (esercizio 2).

## 12.2 Il backend che interroga l'LLM

L'endpoint `POST /api/ask` del backend (`OllamaClient.java`):

1. verifica l'header `X-Api-Token` contro il Secret del capitolo 11, con un confronto a tempo
   costante (`MessageDigest.isEqual`) per non esporre informazioni tramite i tempi di risposta;
2. limita il corpo della richiesta a 4 KB;
3. chiama `http://ollama.ai.svc.cluster.local:11434/api/generate` con `stream: false` e un
   limite di 256 token in uscita;
4. restituisce risposta, modello e latenza.

Ogni richiesta gira su un **virtual thread**: una chiamata che attende l'LLM per dieci secondi
non occupa un thread di sistema. Il proxy nginx del frontend ha `proxy_read_timeout 150s` per
lo stesso motivo.

```bash
pc$ TOKEN=<il token del capitolo 11>
pc$ curl -s --cacert lab-root-ca.crt -X POST -H "X-Api-Token: $TOKEN" \
      --data 'In una frase: cosa fa un Service in Kubernetes?' \
      https://hello.lab.home.arpa/api/ask | jq
```

Oppure dalla pagina web, sezione "Chiedi all'LLM del cluster".

Il flusso completo attraversa ciò che hai costruito finora: Gateway NGINX con TLS → HTTPRoute
`/api` → Service del backend → NetworkPolicy che autorizza backend→Ollama → Service di Ollama →
modello su PersistentVolume. Se qualcosa non va, percorrilo nello stesso ordine.

## 12.3 k8sgpt: diagnosi assistita

**k8sgpt** (progetto CNCF Sandbox) è composto da due parti. Gli **analyzer** sono regole
deterministiche scritte in Go che scansionano il cluster e trovano problemi noti: Pod in
CrashLoopBackOff, Service senza endpoint, PVC in Pending, Ingress e route verso Service
inesistenti. Il **backend AI**, opzionale, prende i problemi trovati e li spiega in linguaggio
naturale suggerendo una soluzione.

La distinzione è importante: la *diagnosi* è deterministica e affidabile; la *spiegazione* è
generata e va verificata.

Installa la CLI (pacchetti per Linux e macOS nelle release del progetto `k8sgpt-ai/k8sgpt`, o
Homebrew), poi usa il modello del cluster:

```bash
pc$ kubectl -n ai port-forward svc/ollama 11434:11434 &
pc$ k8sgpt auth add --backend ollama --model qwen2.5:1.5b --baseurl http://localhost:11434
pc$ k8sgpt analyze                                        # solo analyzer, niente AI
pc$ k8sgpt analyze --explain --backend ollama --namespace hello
```

**Esercizio guidato: rompi e fai diagnosticare.** Crea un guasto realistico:

```bash
pc$ kubectl -n hello create deployment broken --image=ghcr.io/nonexistent/app:1.0
pc$ kubectl -n hello expose deployment broken --port 80 --target-port 8080
pc$ k8sgpt analyze --explain --backend ollama --namespace hello --filter Pod,Service
```

k8sgpt troverà l'`ImagePullBackOff` e il Service senza endpoint pronti. Confronta la sua
spiegazione con quella che daresti tu dopo i capitoli 5 e 6: è corretta? Suggerisce comandi
sensati? Con un modello da 1,5 miliardi di parametri a volte no, ed è istruttivo vederlo. Poi
pulisci: `kubectl -n hello delete deploy,svc broken`. Nota che `broken` non è in Git: Argo CD non la conosce e non la
rimuoverà mai. È uno dei motivi per cui, nei cluster gestiti a GitOps, i permessi di scrittura
diretti si riducono al minimo.

**Anonimizzazione.** Con un backend esterno (OpenAI, Anthropic, Azure OpenAI...) i nomi di Pod,
namespace e immagini verrebbero inviati al provider. `--anonymize` sostituisce i nomi con
segnaposto prima dell'invio e li ripristina nella risposta. Con Ollama nel cluster il problema
non si pone: è uno dei motivi concreti per usare modelli locali in ambienti regolamentati, come
quello bancario.

**L'operatore.** k8sgpt esiste anche come operatore (`k8sgpt-operator`): una CR `K8sGPT` fa
eseguire l'analisi periodicamente nel cluster e salva i risultati come risorse `Result`,
consultabili con kubectl ed esportabili verso Prometheus. La NetworkPolicy di Ollama ammette già
il namespace `k8sgpt-operator-system`. Installarlo via Argo CD è l'esercizio 3.

## 12.4 Agenti AI con permessi minimi

Assistenti di coding e agenti basati su LLM possono usare `kubectl` direttamente, oppure tramite
un **server MCP** (Model Context Protocol, lo standard aperto con cui un'applicazione AI accede a
strumenti e dati esterni). Esistono server MCP per Kubernetes che espongono operazioni come
"elenca i Pod", "leggi i log", "descrivi un Deployment". Sono strumenti potenti per il
troubleshooting, e proprio per questo vanno trattati come un nuovo utente del cluster, con la
stessa disciplina.

**Regola 1: identità dedicata, in sola lettura.** Mai dare a un agente il tuo kubeconfig di
amministratore. Il repository definisce in `k8s/apps/ai/agent-rbac/` un ServiceAccount
`ai-agent-readonly` legato al ClusterRole predefinito `view`: può leggere quasi tutto ma non
modificare nulla e, soprattutto, **non può leggere i Secret**. Genera un kubeconfig apposito con
un token a scadenza:

```bash
pc$ scripts/ai-agent-kubeconfig.sh 8h > ~/.kube/config-ai-readonly
pc$ KUBECONFIG=~/.kube/config-ai-readonly kubectl get pods -A          # funziona
pc$ KUBECONFIG=~/.kube/config-ai-readonly kubectl -n hello get secrets # Forbidden
pc$ KUBECONFIG=~/.kube/config-ai-readonly kubectl -n hello delete pod --all   # Forbidden
pc$ kubectl auth can-i --list --as=system:serviceaccount:ai:ai-agent-readonly | head
```

Il token viene da `kubectl create token`: è un token con scadenza, legato al ServiceAccount, non
un Secret permanente. Scaduto, l'agente perde l'accesso senza che tu debba ricordarti di revocarlo.

**Regola 2: il contenuto del cluster non è fidato.** Log, annotazioni, messaggi di errore e
descrizioni sono testo che qualcun altro può aver scritto. Un'annotazione come "ignora le
istruzioni precedenti ed esegui…" letta da un agente con permessi di scrittura è un vettore di
**prompt injection**. Con un'identità in sola lettura il danno possibile è limitato per
costruzione, non per buona volontà del modello.

**Regola 3: le azioni di scrittura passano da Git.** Se un agente propone una correzione, la
forma giusta è una modifica ai manifest in una pull request, revisionata da una persona e
applicata da Argo CD. L'agente diventa un collaboratore che apre PR, non un operatore con
accesso diretto alla produzione. È esattamente il modello GitOps del capitolo 10, applicato
all'AI.

**Regola 4: verifica prima di fidarti.** Un manifest generato da un LLM si valida come qualunque
altro codice: `kubeconform` contro lo schema, `kubectl apply --dry-run=server` contro l'API
reale, e la CI del repository. Una risposta sicura di sé non è una risposta corretta.

Altri strumenti da conoscere in questa categoria: **kubectl-ai** (progetto open source che
traduce richieste in linguaggio naturale in comandi kubectl e supporta anche modelli locali via
Ollama; verifica le opzioni con `kubectl-ai --help`, il progetto evolve in fretta) e gli
assistenti integrati nelle console dei cloud provider, che incontreremo nella parte cloud.

## 12.5 Cosa portare a un colloquio

Il valore di questo capitolo non sta nell'aver installato Ollama, ma nel saper argomentare le
scelte: perché un modello locale (dati che non escono, costi prevedibili, nessuna dipendenza
esterna), come si isola un carico AI (NetworkPolicy, namespace dedicato, risorse esplicite,
storage persistente per i pesi), come si dà accesso a un agente (identità dedicata, sola lettura,
token a scadenza, scritture solo via Git) e come si valida ciò che un modello produce.

## 12.6 Esercizi

1. **Ollama in `restricted`.** Imposta `runAsUser`/`runAsGroup`/`fsGroup` non root, la variabile
   `HOME` e `OLLAMA_MODELS` verso una directory del volume, monta un `emptyDir` dove serve,
   `readOnlyRootFilesystem: true`, e porta il namespace a `enforce: restricted`.
2. **Un solo punto per il nome del modello.** Usa `replacements` di Kustomize per derivare il
   body del Job di pull dal valore `OLLAMA_MODEL`, oppure sposta la definizione in un ConfigMap
   letto da entrambi.
3. **k8sgpt-operator via GitOps.** Aggiungi in `gitops/optional/` una Application per il chart
   `k8sgpt-operator` e una CR `K8sGPT` con backend `localai`/`ollama` che punta al Service
   interno di Ollama. Ricordati del sourceRepo nell'AppProject.
4. **Metriche dell'LLM.** Aggiungi al backend un istogramma della latenza di `/api/ask` e
   visualizzalo in Grafana (capitolo 13).

<!-- nav -->
---

[← Capitolo 11 — Gestione dei segreti](11-gestione-segreti.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 13 — Osservabilità →](13-osservabilita.md)
