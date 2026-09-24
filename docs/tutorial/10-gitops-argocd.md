# Capitolo 10 — GitOps con Argo CD

## 10.1 Il problema che GitOps risolve

Nei capitoli precedenti hai applicato manifest con kubectl, modificato una ConfigMap a mano,
creato un Secret da riga di comando. Chiediti ora: qual è la verità su cosa gira nel cluster?
La risposta onesta è "quello che c'è nel cluster in questo momento". Nessuna revisione, nessuna
storia, nessun modo affidabile di ricrearlo.

**GitOps** capovolge il rapporto: la verità è nel repository Git, e un agente nel cluster fa sì
che il cluster le corrisponda. I quattro principi, come li formula il progetto OpenGitOps:

1. **Dichiarativo** — il sistema è descritto come stato desiderato, non come sequenza di comandi.
2. **Versionato e immutabile** — lo stato desiderato è conservato in modo da avere storia completa.
3. **Prelevato automaticamente** — gli agenti vanno a prendere lo stato dalla sorgente.
4. **Riconciliato continuamente** — gli agenti osservano lo stato reale e lo correggono.

Il terzo punto è il più importante per la sicurezza. Nel modello *push* classico, la pipeline di
CI esegue `kubectl apply` e quindi possiede le credenziali di amministrazione del cluster: se la
CI viene compromessa, viene compromesso il cluster. Nel modello *pull* la CI scrive solo in Git;
è il cluster che va a prendersi le modifiche. Le credenziali del cluster non lasciano mai il
cluster.

Il quarto punto è il ciclo di riconciliazione del capitolo 1, applicato all'intero sistema.

## 10.2 L'architettura di Argo CD

- **argocd-server** — API, interfaccia web e endpoint per la CLI.
- **argocd-repo-server** — clona i repository e **rende** i manifest: esegue Kustomize, Helm o
  legge YAML puro. Non ha accesso al cluster. Per i chart Helm esegue l'equivalente di
  `helm template`: nel cluster non nasce nessun release Helm (vedi 5B.10).
- **argocd-application-controller** — il cuore: confronta i manifest resi con lo stato del
  cluster, calcola le differenze, esegue le sincronizzazioni, valuta lo stato di salute.
- **redis** — cache.
- **applicationset-controller** — genera Application da modelli (utile per multi-cluster).
- dex e notifications — disabilitati nel nostro laboratorio.

## 10.3 I concetti

Un'**Application** collega una **sorgente** (repository, revisione, percorso; oppure un chart
Helm) a una **destinazione** (cluster e namespace). Ogni Application ha due stati indipendenti:

- **Sync status**: `Synced` o `OutOfSync`. Il cluster corrisponde a Git?
- **Health status**: `Healthy`, `Progressing`, `Degraded`, `Missing`, `Suspended`. Le risorse
  funzionano? Argo CD conosce le regole di salute dei tipi comuni (un Deployment è sano quando
  il rollout è completo) e se ne possono aggiungere.

Un'app può essere `Synced` ma `Degraded`: Git è applicato fedelmente, ma quello che dice non
funziona (un'immagine inesistente, per esempio).

La **syncPolicy** decide cosa fa Argo CD quando nota una differenza:

- `automated` — sincronizza da solo; senza, mostra `OutOfSync` e attende un click o un comando;
- `prune: true` — cancella dal cluster le risorse rimosse da Git. Senza, restano orfane;
- `selfHeal: true` — annulla le modifiche fatte direttamente nel cluster.

Un **AppProject** delimita cosa le Application possono fare: da quali repository leggere, in
quali namespace scrivere, quali risorse a livello di cluster creare. È un confine di sicurezza:
un team con un progetto limitato al suo namespace non può, nemmeno per errore, creare un
ClusterRoleBinding. Guarda `terraform/02-platform-config/manifests/argocd-appproject.yaml`: la
lista dei tipi cluster-wide consentiti è esplicita.

Le **sync wave** ordinano le risorse durante una sincronizzazione: prima la wave `-1`, poi `0`,
e così via; Argo CD attende che ogni wave sia sana prima di passare alla successiva. Gli **hook**
(`PreSync`, `Sync`, `PostSync`, `SyncFail`) sono risorse, tipicamente Job, eseguite in momenti
precisi: migrazioni di database prima del deploy, test di fumo dopo, notifiche in caso di errore.

Argo CD deve anche ricordare quali risorse del cluster appartengono a quale Application: dalla
versione 3 lo fa per default con un'**annotazione** di tracciamento sulle risorse.

## 10.4 Il pattern app-of-apps

Terraform crea una sola Application, `root`, che punta alla cartella `gitops/apps/`. Quella
cartella contiene **altre Application**. Argo CD sincronizza la root, che crea le figlie, che
creano le applicazioni vere.

```
 root  (Terraform)  ──►  gitops/apps/
                           ├── sealed-secrets.yaml   wave -1  chart Helm → kube-system
                           ├── ai.yaml               wave  0  k8s/apps/ai/ollama → ai
                           ├── ai-agent-rbac.yaml    wave  1  k8s/apps/ai/agent-rbac
                           └── hello.yaml            wave  2  k8s/apps/hello/overlays/lab → hello
```

Da questo momento, **aggiungere qualcosa al cluster significa aggiungere un file in
`gitops/apps/` e fare commit**. Terraform non viene più toccato per le applicazioni. È il confine
di proprietà descritto nel README: Terraform possiede la piattaforma, Argo CD possiede i carichi.

Nota in `hello.yaml`:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    name: hello-backend
    jsonPointers: [/spec/replicas]
syncOptions:
  - RespectIgnoreDifferences=true
```

L'HPA modifica `spec.replicas`. Senza queste righe Argo CD vedrebbe una differenza e, con
`selfHeal`, riporterebbe le repliche a 2 subito dopo ogni scalata: HPA e Argo CD si
combatterebbero in un ciclo infinito. `ignoreDifferences` esclude il campo dal confronto;
`RespectIgnoreDifferences` lo esclude anche quando Argo CD applica le modifiche per altri motivi.
È la regola "un solo proprietario" applicata a un singolo campo.

## 10.5 Prerequisiti

1. Il tuo repository su GitHub, con `scripts/set-repo-url.sh` già eseguito e committato.
   Repository pubblico, oppure credenziali registrate in Argo CD (`argocd repo add` con un token
   in sola lettura).
2. Le immagini pubblicate su GHCR e raggiungibili dal cluster (capitolo 4, oppure la CI in 10.8).
3. In GitHub → Settings → Actions → General → Workflow permissions: **Read and write**, perché la
   CI deve poter committare il nuovo tag.

## 10.6 Accendere GitOps

```bash
pc$ $EDITOR terraform/02-platform-config/terraform.tfvars    # enable_gitops = true
pc$ make platform-config
pc$ kubectl -n argocd get applications                       # root, sealed-secrets, ai-ollama, ai-agent-rbac, hello
```

Le risorse di `hello` che avevi creato con kubectl hanno gli stessi nomi di quelle nel
repository: Argo CD le **adotta** applicandoci sopra i manifest di Git. La modifica manuale del
saluto del capitolo 5 sparisce: il cluster ora dice quello che dice Git. Il Secret creato a mano
invece resta, perché Argo CD gestisce solo ciò che conosce: sarà sostituito nel capitolo 11.

Accedi all'interfaccia:

```bash
pc$ make argocd-password
# browser: https://argocd.lab.home.arpa   utente: admin
pc$ argocd login argocd.lab.home.arpa --grpc-web --username admin
pc$ argocd account update-password
pc$ kubectl -n argocd delete secret argocd-initial-admin-secret     # non serve più
```

`--grpc-web` serve perché la CLI parla gRPC e il Gateway inoltra HTTP/1.1 e HTTP/2 in modo
standard; gRPC-Web passa attraverso qualunque proxy HTTP. Esplora l'albero delle risorse di
`hello` nell'interfaccia: vedrai Deployment, ReplicaSet, Pod, EndpointSlice, con stato e log.

```bash
pc$ argocd app list
pc$ argocd app get hello
pc$ argocd app diff hello        # cosa cambierebbe un sync (vuoto se Synced)
```

## 10.7 Esercizi fondamentali

**1. Un cambiamento via Git.** Modifica la patch nell'overlay `k8s/apps/hello/overlays/lab/
kustomization.yaml` aggiungendo un cambio del `GREETING`, commit e push. Entro un minuto l'app
diventa `OutOfSync`, poi `Synced`. Hai cambiato una ConfigMap: i Pod si riavviano? No, per il
motivo visto nel capitolo 5. Passa al `configMapGenerator` (esercizio del capitolo 5) e riprova.

**2. Self-heal.** Simula un collega frettoloso:

```bash
pc$ kubectl -n hello scale deploy hello-frontend --replicas=5
pc$ kubectl -n hello delete service hello-frontend
pc$ kubectl -n hello get deploy,svc -w
```

In pochi secondi Argo CD riporta le repliche a 2 e ricrea il Service. Guarda la cronologia degli
eventi dell'app nell'interfaccia.

**3. Rollback con Git.** `git revert HEAD && git push`. Il rollback è un commit come un altro:
tracciato, revisionabile, con autore e motivazione. `argocd app rollback` esiste, ma con la sync
automatica attiva Argo CD si rifiuta di usarlo: in GitOps il rollback si fa nella sorgente di
verità.

**4. Rompere qualcosa.** Metti nell'overlay un tag immagine inesistente e fai push. L'app sarà
`Synced` ma `Degraded`: il nuovo ReplicaSet non parte (ImagePullBackOff), e grazie a
`maxUnavailable: 0` i Pod vecchi continuano a servire il traffico. L'utente non si accorge di
nulla. Correggi con un revert.

## 10.8 La pipeline completa: CI che scrive in Git

`.github/workflows/ci.yml` ha tre job:

1. **validate** — rende i manifest con Kustomize e li valida con **kubeconform** contro gli schemi
   di Kubernetes (e quelli delle CRD, dal catalogo della comunità); `terraform fmt` e `validate`;
   `ansible-lint`. Gira anche sulle pull request.
2. **build** — per backend e frontend: build con buildx, cache delle layer, push su GHCR con tag
   `0.1.<numero-run>-<sha>`, SBOM e attestazione di provenienza. Sulle pull request costruisce
   senza pubblicare.
3. **bump** — solo su `main`: `kustomize edit set image` aggiorna i tag nell'overlay e committa.

```
 push su main ─► validate ─► build (GHCR) ─► bump: commit "deploy(lab): hello 0.1.42-ab12cd3"
                                                        │
                        Argo CD (nel cluster) ◄── poll ─┘ ─► rolling update
```

Due dettagli da notare. Il workflow ignora i push che modificano solo l'overlay
(`paths-ignore`), quindi il commit di bump non fa ripartire la pipeline in un ciclo infinito (i
push fatti con il `GITHUB_TOKEN` non attivano comunque nuovi workflow, ma è bene essere espliciti).
E la CI non contiene nessuna credenziale del cluster: il perimetro di sicurezza è Git.

La prima esecuzione crea i pacchetti su GHCR come privati: rendili pubblici come nel capitolo 4.

Alternativa da conoscere: **Argo CD Image Updater** osserva il registry e aggiorna i tag da solo
(scrivendo in Git o nei parametri dell'Application). Riduce il lavoro della CI, ma sposta una
decisione di rilascio fuori dalla pipeline: è una scelta di processo.

## 10.9 Troubleshooting di Argo CD

- **`ComparisonError` o repository non raggiungibile** — URL sbagliato, repository privato senza
  credenziali. `argocd repo list`.
- **OutOfSync perenne senza modifiche apparenti** — un controller o un webhook aggiunge campi di
  default che Argo CD vede come differenze. `argocd app diff` mostra quali; si risolve con
  `ignoreDifferences` mirato o con `ServerSideApply=true`.
- **Sync fallito per risorsa sconosciuta** — la CRD non è ancora installata: serve una sync wave
  precedente per chi installa la CRD, oppure `SkipDryRunOnMissingResource=true`.
- **Application che non si cancella** — il finalizer `resources-finalizer.argocd.argoproj.io`
  attende la cancellazione delle risorse figlie. Controlla quale risorsa blocca, prima di
  rimuovere il finalizer a mano.
- **Il Deployment continua a tornare a 2 repliche** — manca `ignoreDifferences` (vedi 10.4).

## 10.10 Argo CD o Flux?

Flux è l'altro progetto GitOps graduato della CNCF. Flux è un insieme di controller senza
interfaccia grafica, configurato interamente con CRD; Argo CD offre un'interfaccia ricca, un
modello di progetti multi-team e una CLI potente. I principi sono gli stessi e ciò che impari
qui si trasferisce. Nei colloqui la domanda frequente non è quale sia migliore, ma se sai
spiegare il modello pull e la riconciliazione.

<!-- nav -->
---

[← Capitolo 9 — Terraform: la piattaforma come codice](09-terraform.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 11 — Gestione dei segreti →](11-gestione-segreti.md)
