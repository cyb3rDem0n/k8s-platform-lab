# Capitolo 4 — Un backend Java pensato per Kubernetes

Un'applicazione "gira su Kubernetes" in due modi: perché qualcuno l'ha messa in un container, o
perché è stata progettata per collaborare con la piattaforma. La differenza si vede durante un
aggiornamento, un picco di carico o un nodo che muore. In questo capitolo progettiamo la
seconda.

## 4.1 Cosa fa l'applicazione

Il backend (`app/backend`) è volutamente scritto con il solo JDK: `com.sun.net.httpserver` per
servire HTTP e `java.net.http` per chiamare altri servizi. Nessun framework, nessuna dipendenza:
ogni riga è leggibile e l'immagine finale pesa circa 50 MB. In un progetto reale useresti
Spring Boot, Quarkus o Micronaut, e tutto quello che impari qui si applica identico.

Gli endpoint:

- `GET /api/hello` — un saluto con il nome del Pod che ha risposto. Chiamandolo più volte vedi il
  bilanciamento tra le repliche.
- `GET /api/info` — metadati non sensibili: ambiente, versione, versione di Java, se il token
  API è configurato (mai il token stesso).
- `POST /api/ask` — invia il corpo della richiesta come prompt a un LLM che gira nel cluster
  (capitolo 12). Protetto dall'header `X-Api-Token`, il cui valore arriva da un Secret.
- `GET /healthz/live` e `GET /healthz/ready` — le probe di Kubernetes.
- `GET /metrics` — metriche in formato Prometheus (capitolo 13).

Il frontend (`app/frontend`) è una pagina statica servita da nginx, che chiama le API.

## 4.2 I principi: la "Twelve-Factor App" applicata

La metodologia Twelve-Factor è di più di dieci anni fa ma descrive ancora bene cosa si aspetta
Kubernetes da un'applicazione. Ecco come la applichiamo, fattore per fattore dove conta:

**Configurazione nell'ambiente (III).** `Config.java` legge tutto da variabili d'ambiente:
porta, nome, saluto, URL dell'LLM, token. La stessa immagine gira identica in locale, sul NUC e
nel cloud; cambia solo ciò che le passi. In Kubernetes le variabili arrivano da una ConfigMap
(dati non sensibili) e da un Secret (dati sensibili). Nota anche `Config.toString()`: stampa se
il token è presente, mai il suo valore. I log finiscono in sistemi centralizzati letti da molte
persone.

**Servizi di supporto come risorse collegate (IV).** L'LLM è raggiunto tramite un URL
configurabile. Per l'applicazione non fa differenza se è Ollama nel cluster, un servizio in un
altro namespace o un'API cloud.

**Processi stateless (VI).** Nessuno stato in memoria che debba sopravvivere al Pod. Qualunque
replica può rispondere a qualunque richiesta, quindi possiamo averne quante ne vogliamo e
ucciderne una in qualunque momento.

**Port binding (VII).** L'applicazione espone HTTP su una porta propria; non ha bisogno di un
application server esterno.

**Disponibilità a essere terminati (IX).** Avvio veloce e **arresto controllato**. È il punto
più trascurato e merita una sezione a parte.

**Log come flussi di eventi (XI).** Una riga per evento su stdout. Il kubelet raccoglie
stdout/stderr dei container; `kubectl logs` e qualunque sistema di logging li leggono da lì.
Nessun file di log dentro il container.

## 4.3 Graceful shutdown: cosa succede quando un Pod viene terminato

Durante un rolling update, uno scale-down o un drain del nodo, Kubernetes termina dei Pod. La
sequenza è questa, e contiene una **gara** che causa errori 502 in moltissime applicazioni:

```
 t=0   Il Pod passa in stato Terminating. Da qui partono IN PARALLELO due catene:

 Catena A (piano di controllo)             Catena B (il nodo)
 ───────────────────────────────           ─────────────────────────────────
 EndpointSlice controller rimuove          kubelet esegue il preStop hook (se c'è),
 l'IP del Pod dagli endpoint.              poi invia SIGTERM al processo.
 kube-proxy e Gateway ricevono
 l'aggiornamento e smettono di
 inviare traffico. Richiede tempo:
 da qualche centinaio di ms
 a qualche secondo.

 t=terminationGracePeriodSeconds: se il processo è ancora vivo, SIGKILL.
```

Se l'applicazione, ricevuto SIGTERM, chiude subito il socket, mentre la catena A non ha ancora
finito di propagarsi, il Gateway continua a inviare richieste a un processo che non ascolta più:
errori per i client, a ogni deploy.

La soluzione ha due fasi, implementate in `App.shutdown()`:

1. Alla ricezione di SIGTERM la readiness diventa falsa (`/healthz/ready` risponde 503) e il
   processo **continua a servire** per `SHUTDOWN_DELAY_SECONDS` (5 s). È il tempo per far
   propagare la rimozione dell'endpoint.
2. Poi `server.stop(SHUTDOWN_GRACE_SECONDS)` smette di accettare connessioni e concede fino a
   10 s alle richieste in corso per terminare.

La somma (15 s) deve stare comodamente sotto `terminationGracePeriodSeconds` (30 s nel
Deployment), altrimenti il kubelet interrompe tutto con SIGKILL a metà.

Per il frontend nginx, che non conosciamo dall'interno, usiamo l'altra tecnica: un **preStop
hook** `sleep: 5` (azione nativa del kubelet, senza bisogno di una shell nel container). Il
kubelet attende 5 secondi prima di inviare SIGTERM; nel frattempo l'endpoint viene rimosso.
nginx, ricevuto SIGTERM, ha già smesso di ricevere nuove richieste.

## 4.4 Le tre probe e cosa NON devono controllare

- **startupProbe** — "l'applicazione ha finito di avviarsi?". Finché non ha successo, le altre
  due probe sono sospese. Serve per applicazioni lente a partire (la JVM con molte classi) senza
  dover allungare i timeout della liveness.
- **livenessProbe** — "il processo è vivo o è bloccato?". Se fallisce ripetutamente, il kubelet
  **riavvia il container**.
- **readinessProbe** — "il processo può ricevere traffico adesso?". Se fallisce, il Pod viene
  tolto dagli endpoint del Service ma **non** viene riavviato.

L'errore classico è far controllare alla liveness le dipendenze esterne (database, LLM). Se
l'LLM rallenta, tutte le liveness falliscono insieme, Kubernetes riavvia tutti i backend, e un
problema locale diventa un disservizio totale. Regola: la liveness controlla solo il processo
stesso. Anche la readiness va usata con cautela sulle dipendenze condivise: se tutte le repliche
diventano non pronte nello stesso istante, il Service resta senza endpoint. Nel nostro backend
la readiness riflette solo lo stato di shutdown; se l'LLM non risponde, `/api/ask` restituisce
502 ma il resto dell'applicazione continua a funzionare. Si chiama *degradazione controllata*.

## 4.5 Virtual thread

`server.setExecutor(Executors.newVirtualThreadPerTaskExecutor())` assegna un virtual thread a
ogni richiesta. I virtual thread (stabili da Java 21) sono gestiti dalla JVM e costano pochi
kilobyte: quando un thread si blocca su I/O, ad esempio mentre attende per decine di secondi la
risposta dell'LLM, la JVM libera il thread di sistema sottostante per altro lavoro. Scrivi
codice bloccante semplice e ottieni la scalabilità del codice asincrono. Per un backend che
passa la maggior parte del tempo ad aspettare altri servizi è la scelta naturale.

## 4.6 Il Dockerfile, riga per riga

```dockerfile
FROM eclipse-temurin:25-jdk-noble AS build
```

**Build multi-stage.** Il primo stage contiene il JDK completo, serve solo per compilare e non
finirà nell'immagine finale. Java 25 è l'LTS corrente.

```dockerfile
RUN javac --release 25 -Xlint:all -d out $(find src/main/java -name '*.java') \
 && jar --create --file app.jar --main-class lab.hello.App -C out .
RUN jlink --add-modules java.base,java.net.http,jdk.httpserver,jdk.crypto.ec \
          --strip-debug --no-man-pages --no-header-files --compress=zip-6 --output /jre
```

**jlink** costruisce un runtime Java contenente solo i moduli che usiamo. Il JRE completo pesa
circa 200 MB; il nostro circa 45 MB. Meno codice significa meno vulnerabilità da gestire e pull
più veloci. Se aggiungi una dipendenza, `jdeps --print-module-deps app.jar` ti dice quali moduli
servono.

```dockerfile
FROM gcr.io/distroless/base-debian12:nonroot
```

**Distroless.** L'immagine finale contiene glibc, certificati CA, fuso orario e poco altro.
Niente shell, niente package manager, niente `curl`. Se un attaccante ottiene esecuzione di
codice nel container, non ha strumenti a disposizione. Il tag `nonroot` imposta l'utente 65532.

Il rovescio della medaglia: `kubectl exec -it ... -- sh` non funziona. Per il debug si usano i
**container effimeri** (`kubectl debug`, capitolo 5), che aggiungono temporaneamente al Pod un
container con gli strumenti necessari.

```dockerfile
ENV JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=75 -XX:+ExitOnOutOfMemoryError"
```

La JVM moderna legge i limiti del cgroup: con un limite di 256 Mi e `MaxRAMPercentage=75`
l'heap massimo sarà circa 192 Mi. Il restante 25% serve a metaspace, stack dei thread, buffer
nativi e code cache. Se l'heap arrivasse al 100% del limite, il kernel ucciderebbe il container
(OOMKilled) senza che la JVM possa nemmeno scrivere un messaggio.

`ExitOnOutOfMemoryError`: se la JVM esaurisce l'heap, termina subito invece di continuare in uno
stato degradato. Kubernetes la riavvierà pulita. Principio generale: **fallisci in fretta e lascia
che la piattaforma recuperi**.

```dockerfile
USER 65532:65532
```

Ridondante con l'immagine `nonroot`, ma esplicito: chi legge il Dockerfile sa subito con che
utente gira il processo. E Kubernetes, con `runAsNonRoot: true`, rifiuterà di avviare l'immagine
se qualcuno dovesse cambiarla per girare come root.

## 4.7 Tag delle immagini: immutabili, mai `latest`

Un tag come `latest` o `main` cambia contenuto nel tempo: due nodi potrebbero eseguire codice
diverso con lo stesso nome, e un rollback non è più possibile perché non sai cosa c'era prima.
Usiamo tag immutabili: `0.1.0` per il primo rilascio manuale, poi `0.1.<run>-<sha>` generati
dalla CI, che legano ogni immagine al commit da cui nasce. Il massimo del rigore è il digest
(`@sha256:...`), che identifica il contenuto in modo univoco; alcune pipeline lo scrivono
direttamente nei manifest.

La CI di questo repository pubblica anche SBOM (l'elenco dei componenti dell'immagine) e
attestazione di provenienza, i due mattoni della sicurezza della supply chain (SLSA).

## 4.8 Build e push su GitHub Container Registry

Il NUC è x86_64. Se costruisci da un Mac con Apple Silicon, aggiungi `--platform linux/amd64`.

```bash
pc$ export GH_USER=<tu>
pc$ # Token classico con scope write:packages (GitHub → Settings → Developer settings)
pc$ echo "$GHCR_PAT" | docker login ghcr.io -u "$GH_USER" --password-stdin

pc$ docker build --build-arg APP_VERSION=0.1.0 \
      -t ghcr.io/$GH_USER/k8s-platform-lab-backend:0.1.0 app/backend
pc$ docker build -t ghcr.io/$GH_USER/k8s-platform-lab-frontend:0.1.0 app/frontend
pc$ docker push ghcr.io/$GH_USER/k8s-platform-lab-backend:0.1.0
pc$ docker push ghcr.io/$GH_USER/k8s-platform-lab-frontend:0.1.0
```

I pacchetti su GHCR nascono **privati**. Per il laboratorio rendili pubblici (GitHub → il tuo
profilo → Packages → pacchetto → Package settings → Change visibility). In alternativa, e con un
registry aziendale sarebbe l'unica via, crea un pull secret e collegalo al ServiceAccount:

```bash
pc$ kubectl -n hello create secret docker-registry ghcr-pull \
      --docker-server=ghcr.io --docker-username=$GH_USER --docker-password=$GHCR_PAT_READ
pc$ kubectl -n hello patch serviceaccount hello-backend -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
```

Terza via, utile senza registry: caricare l'immagine direttamente in containerd sul NUC.

```bash
pc$ docker save ghcr.io/$GH_USER/k8s-platform-lab-backend:0.1.0 \
      | ssh giuseppe@192.168.1.50 sudo ctr -n k8s.io images import -
```

Il namespace `k8s.io` di containerd è quello usato dal kubelet. Con `imagePullPolicy:
IfNotPresent` il Pod userà l'immagine locale.

## 4.9 Provare in locale con Docker Compose

Prima di portare un'immagine sul cluster, verifica che funzioni:

```bash
pc$ docker compose up --build
pc$ curl -s localhost:8080/api/hello
pc$ docker compose --profile ai up -d && docker compose exec ollama ollama pull qwen2.5:1.5b
pc$ curl -s -X POST -H 'X-Api-Token: dev-token-solo-locale' -d 'Ciao!' localhost:8080/api/ask
```

La configurazione di nginx (`app/frontend/nginx/default.conf`) punta a `hello-backend:8080`:
in Compose è il nome del servizio, in Kubernetes è il nome del Service nello stesso namespace.
Stessa configurazione, due ambienti: è il vantaggio di usare nomi logici invece di indirizzi.

<!-- nav -->
---

[← Capitolo 3 — Automatizzare il nodo con Ansible](03-automazione-con-ansible.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 5 — Il primo deploy →](05-primo-deploy.md)
