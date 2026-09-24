# Capitolo 5B — Helm: il package manager di Kubernetes

Questo capitolo fa da ponte. Dal capitolo 6 installerai MetalLB, NGINX Gateway Fabric e
cert-manager con Helm; nel capitolo 9 Terraform userà Helm tramite `helm_release`; nel capitolo 10
Argo CD installerà Sealed Secrets e kube-prometheus-stack da chart Helm. Prima di usarlo come
strumento, conviene capirlo come si deve: cosa fa, come ragiona, dove può tradirti.

Il capitolo ha due metà. Nella prima usi chart scritti da altri, come farai con quasi tutto il
software di piattaforma. Nella seconda leggi e installi `charts/hello`, un chart che impacchetta
la stessa applicazione del capitolo 5: così puoi confrontare Helm e Kustomize sullo stesso
problema.

## 5B.1 Il problema che Helm risolve

Nel capitolo 5 hai applicato una decina di manifest. Ora immagina di dover:

- installare cert-manager, che sono decine di manifest tra CRD, RBAC, Deployment e webhook, e
  poi aggiornarlo a ogni release senza dimenticare nulla;
- installare la stessa applicazione in tre ambienti che differiscono per repliche, hostname e
  risorse;
- sapere in ogni momento **quale versione** di un componente è installata, e poter **tornare
  indietro** con un comando.

Kustomize risolve bene il secondo punto. Helm li risolve tutti e tre, perché aggiunge tre idee:
un **pacchetto** versionato e distribuibile (il chart), **parametri** documentati (i values) e un
**ciclo di vita** (install, upgrade, rollback, uninstall) registrato nel cluster.

## 5B.2 I concetti

**Chart.** Il pacchetto: una cartella (o un archivio `.tgz`) con questa struttura.

```
charts/hello/
├── Chart.yaml          nome, versione del chart, versione dell'app, dipendenze
├── values.yaml         parametri con i loro default: il "contratto" del chart
├── values.schema.json  validazione dei parametri (opzionale ma professionale)
├── templates/          manifest scritti come template Go
│   ├── _helpers.tpl    funzioni riutilizzabili (i file che iniziano con _ non producono risorse)
│   ├── NOTES.txt       messaggio mostrato dopo install e upgrade
│   └── tests/          Pod eseguiti da `helm test`
├── crds/               CRD installate prima di tutto (con regole particolari, vedi 5B.7)
└── charts/             chart da cui questo dipende (sottochart)
```

Un chart ha **due versioni**, e confonderle è un errore classico. `version` è la versione del
chart: cambia ogni volta che cambi il chart, anche solo un template. `appVersion` è la versione
dell'applicazione che il chart installa. Un chart alla versione 3.2.0 può installare
l'applicazione 1.18.

**Values.** I parametri. Il chart li definisce in `values.yaml`; tu li sovrascrivi con file
(`-f valori.yaml`) o con `--set chiave=valore`. L'ordine di precedenza, dal più debole al più
forte: `values.yaml` del chart, poi i file `-f` nell'ordine in cui li passi, poi i `--set`.

**Release.** Un'istanza di un chart installata nel cluster, con un nome, in un namespace. Lo
stesso chart può essere installato più volte con nomi diversi. Ogni install, upgrade o rollback
crea una nuova **revisione**. Helm salva lo stato di ogni revisione (chart, values, manifest
generati) in un Secret del namespace del release, di tipo `helm.sh/release.v1`. Non esiste un
componente server: la CLI parla direttamente con l'API server, con i permessi del tuo kubeconfig.

**Repository.** Dove si pubblicano i chart. Due tipi: il repository **HTTP classico**, un server
web con un file `index.yaml` (si registra con `helm repo add`), e il **registry OCI**, lo stesso
tipo di registry delle immagini container (GHCR, ECR, Artifact Registry, ACR). Con OCI non serve
`repo add`: si usa l'indirizzo `oci://...` direttamente. È la direzione in cui si sta muovendo
l'ecosistema: NGINX Gateway Fabric, per esempio, pubblica solo su OCI.

## 5B.3 Helm 4

Helm 4 è uscito a novembre 2025 ed è la versione da usare oggi (a settembre 2026 la release
corrente è la 4.3). Helm 3 ha ricevuto l'ultima minor, la 3.22, e riceverà solo patch di
sicurezza fino al 10 febbraio 2027. Molti tutorial online mostrano ancora comandi di Helm 3: quasi
tutti funzionano, ma ci sono differenze che devi conoscere.

- **Server-side apply per default** sulle nuove installazioni. Helm 3 usava un "three-way merge"
  lato client; Helm 4 lascia calcolare le modifiche all'API server, come fa `kubectl apply
  --server-side`. Se un altro strumento possiede un campo che il chart vuole modificare, ottieni
  un **errore di conflitto** esplicito invece di una sovrascrittura silenziosa (si forza con
  `--force-conflicts`). I release creati con Helm 3 continuano, agli upgrade, con il metodo
  precedente.
- **Flag rinominati**: `--atomic` è diventato `--rollback-on-failure`, `--force` è diventato
  `--force-replace`. I vecchi nomi funzionano ancora con un avviso: aggiorna gli script.
- **`--wait` più affidabile**: usa la libreria kstatus, che sa quando una risorsa è davvero
  pronta. Richiede il permesso `watch` sulle risorse del chart.
- `helm registry login` accetta **solo il dominio** (`ghcr.io`, non un URL completo).
- I **post-renderer** sono diventati plugin (con un nuovo sistema di plugin, anche WebAssembly).
- I chart con `apiVersion: v2`, cioè praticamente tutti, funzionano **senza modifiche**. Un nuovo
  formato di chart (v3) esiste, ma è sperimentale.

Installa la CLI (con il gestore di pacchetti del tuo sistema, per esempio `brew install helm`,
oppure dalle istruzioni ufficiali su helm.sh) e verifica:

```bash
pc$ helm version          # v4.x
```

## 5B.4 Usare un chart di terzi: il metodo professionale

Il flusso che ripeterai per ogni componente di piattaforma è sempre lo stesso: **scopri, leggi,
rendi, installa con valori in un file e versione bloccata, verifica**. Facciamo pratica con
**podinfo**, una piccola applicazione dimostrativa pensata proprio per questo, pubblicata su un
registry OCI.

**Scopri e leggi.**

```bash
pc$ helm show chart  oci://ghcr.io/stefanprodan/charts/podinfo     # metadati e versione più recente
pc$ helm show values oci://ghcr.io/stefanprodan/charts/podinfo | less
pc$ helm pull oci://ghcr.io/stefanprodan/charts/podinfo --untar -d /tmp/podinfo-chart
pc$ ls /tmp/podinfo-chart/podinfo/templates                        # leggi i template: non è una scatola nera
```

`helm show values` è il documento più importante di un chart: elenca ogni parametro con il suo
default. Leggerlo prima di installare è la differenza tra usare un chart e subirlo.

Annota la versione mostrata da `helm show chart` e usala ovunque sotto al posto di `<VERSIONE>`.
**Bloccare la versione** è obbligatorio: senza `--version`, ogni installazione prende l'ultima
pubblicata, e due installazioni a una settimana di distanza possono essere diverse.

**Scrivi i valori in un file.**

```bash
pc$ cat > /tmp/podinfo-values.yaml <<'EOF'
replicaCount: 2
ui:
  message: "Installato con Helm 4"
resources:
  requests: { cpu: 10m, memory: 32Mi }
  limits: { memory: 64Mi }
EOF
```

*Perché un file e non una serie di `--set`:* il file si versiona in Git, si rivede in una pull
request, si confronta con `helm show values`. Una riga di comando con dieci `--set` non lascia
traccia e non si rilegge. Nel repository, i file in `terraform/01-platform/values/` seguono
esattamente questa regola.

**Rendi prima di installare.** `helm template` genera i manifest in locale, senza toccare il
cluster. È l'equivalente di `kubectl kustomize`:

```bash
pc$ helm template demo oci://ghcr.io/stefanprodan/charts/podinfo --version <VERSIONE> \
      -f /tmp/podinfo-values.yaml | less
```

**Installa.**

```bash
pc$ helm install demo oci://ghcr.io/stefanprodan/charts/podinfo --version <VERSIONE> \
      -n helm-lab --create-namespace -f /tmp/podinfo-values.yaml --wait
pc$ helm list -n helm-lab
pc$ helm status demo -n helm-lab
pc$ kubectl -n helm-lab get all
```

**Ispeziona il release.** Helm ricorda tutto ciò che ha installato:

```bash
pc$ helm get values   demo -n helm-lab          # i valori che HAI passato
pc$ helm get values   demo -n helm-lab --all    # tutti i valori effettivi, default compresi
pc$ helm get manifest demo -n helm-lab          # i manifest esatti applicati
pc$ kubectl -n helm-lab get secrets -l owner=helm   # dove vive lo stato del release
```

**Aggiorna, osserva la storia, torna indietro.**

```bash
pc$ helm upgrade demo oci://ghcr.io/stefanprodan/charts/podinfo --version <VERSIONE> \
      -n helm-lab -f /tmp/podinfo-values.yaml --set ui.message="Revisione 2" --wait
pc$ helm history demo -n helm-lab
pc$ helm rollback demo 1 -n helm-lab --wait
pc$ helm history demo -n helm-lab               # il rollback crea la revisione 3, uguale alla 1
```

Nota che il rollback non cancella la storia: aggiunge una revisione nuova con il contenuto di una
vecchia. È lo stesso principio del `git revert`.

Una trappola da conoscere: `helm upgrade` senza `-f` e senza `--set` **riparte dai default del
chart**, e perdi i valori precedenti. Esistono `--reuse-values` (riusa i valori del release e
ignora i nuovi default del chart, pericoloso quando aggiorni versione) e
`--reset-then-reuse-values` (applica i nuovi default e poi i tuoi valori precedenti). La regola
più semplice e sicura: passa **sempre** lo stesso file di valori a ogni upgrade.

`helm upgrade --install` installa se il release non esiste e aggiorna altrimenti: è la forma da
usare negli script, perché è idempotente. Con `--rollback-on-failure`, se l'upgrade fallisce
Helm torna automaticamente alla revisione precedente.

**Disinstalla.**

```bash
pc$ helm uninstall demo -n helm-lab && kubectl delete namespace helm-lab
```

## 5B.5 Il nostro chart: `charts/hello`

Ora dall'altra parte: come si scrive un chart. `charts/hello` produce le stesse risorse di
`k8s/apps/hello/base` (Deployment, Service, ConfigMap, HPA, PDB, NetworkPolicy, HTTPRoute),
parametrizzate.

### Il linguaggio dei template

I template sono YAML con **azioni** tra doppie graffe, scritte nel linguaggio dei template di Go
arricchito dalla libreria Sprig (un centinaio di funzioni). Gli oggetti principali:

- `.Values` — i valori effettivi, dopo l'unione di default, file e `--set`;
- `.Release` — nome, namespace, `IsInstall`, `IsUpgrade`, `Revision`;
- `.Chart` — il contenuto di `Chart.yaml`;
- `.Capabilities` — versione di Kubernetes e API disponibili nel cluster;
- `.Template` — il file corrente.

Le costruzioni che trovi in `charts/hello/templates`:

```yaml
image: {{ include "hello.image" (dict "ctx" . "image" .Values.backend.image) | quote }}
```

Le **pipeline** (`|`) passano il risultato di una funzione alla successiva, come nella shell.
`quote` mette le virgolette: senza, un valore come `0.10` diventerebbe il numero 0.1, e un tag
`true` un booleano.

```yaml
  labels:
    {{- include "hello.labels" $ctx | nindent 4 }}
```

`{{-` elimina gli spazi e l'a capo **prima** dell'azione, `-}}` quelli **dopo**. `nindent 4`
aggiunge un a capo e indenta ogni riga di quattro spazi. In YAML l'indentazione è sintassi: la
maggior parte degli errori nei chart è qui. Si usa `include` e non `template` proprio perché
`include` restituisce una stringa che puoi passare a `nindent`.

```yaml
{{- if .Values.httpRoute.enabled }} ... {{- end }}
{{- with .Values.imagePullSecrets }} ... {{ toYaml . }} ... {{- end }}
{{- range $key, $value := .Values.backend.config }} ... {{- end }}
```

`if` rende opzionali intere risorse; `with` cambia il contesto (`.`) e salta il blocco se il
valore è vuoto; `range` itera su liste e mappe. `toYaml` converte una struttura di valori in YAML:
è il modo per lasciare all'utente il controllo di blocchi interi, come `resources`.

### Le funzioni di supporto (`_helpers.tpl`)

- `hello.fullname` — il prefisso dei nomi. Con release `hello` e chart `hello` vale `hello`, non
  `hello-hello`: le risorse si chiamano `hello-backend` e `hello-frontend`, come nella versione
  Kustomize. I nomi sono troncati a 63 caratteri, il limite di Kubernetes.
- `hello.selectorLabels` — le etichette dei selettori: **poche e stabili**. Il selettore di un
  Deployment è immutabile: se ci mettessi la versione dell'app, il primo upgrade fallirebbe.
- `hello.labels` — le etichette complete, con la versione del chart e dell'app e
  `app.kubernetes.io/managed-by: Helm`.

I named template ricevono un solo argomento. Per passarne due (il contesto e il nome del
componente) si costruisce un dizionario: `(dict "ctx" . "component" "backend")`. Dentro il
template si usa poi `.ctx.Release.Name`. È un idioma che troverai in molti chart.

### Tre scelte da professionista

**1. Il checksum della configurazione.** Nel capitolo 5 hai visto che cambiare una ConfigMap non
riavvia i Pod. Il Deployment del chart ha questa annotazione:

```yaml
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
```

Se cambia un valore di configurazione, cambia l'hash, cambia il template del Pod, e Kubernetes
esegue un rolling update. È l'equivalente Helm del `configMapGenerator` di Kustomize.

**2. Niente `replicas` quando c'è l'HPA.**

```yaml
{{- if not .Values.backend.autoscaling.enabled }}
replicas: {{ .Values.backend.replicaCount }}
{{- end }}
```

Se il Deployment dichiarasse le repliche, ogni `helm upgrade` le riporterebbe al valore fisso,
annullando il lavoro dell'autoscaler. Omettendo il campo, il proprietario unico delle repliche è
l'HPA. Confrontalo con la soluzione del capitolo 10, `ignoreDifferences` in Argo CD: stesso
problema, due strumenti, due soluzioni.

**3. La validazione dei valori.** `values.schema.json` descrive in JSON Schema tipi e vincoli dei
parametri. Helm lo applica a `lint`, `template`, `install` e `upgrade`. Il nostro schema, tra
l'altro, rifiuta il tag `latest`:

```bash
pc$ helm template hello charts/hello --set backend.image.tag=latest
# Error: values don't meet the specifications of the schema(s) ...
```

Un errore al momento dell'installazione è infinitamente meglio di un Pod che parte con
un'immagine imprevedibile.

### Il namespace non lo crea il chart

È una convenzione consolidata: un chart installa risorse **nel** namespace del release, ma non
crea il namespace stesso. Il motivo è il ciclo di vita: `helm uninstall` cancellerebbe il
namespace e tutto ciò che contiene, anche risorse non sue. Per questo creiamo e prepariamo il
namespace a parte, con le etichette di Pod Security.

## 5B.6 Installare `charts/hello`

Installiamo la versione Helm accanto a quella del capitolo 5, in un namespace separato, così le
due convivono e puoi confrontarle.

```bash
pc$ helm lint --strict charts/hello
pc$ helm template hello charts/hello -n hello-helm | less          # leggi cosa verrà creato
pc$ kubectl create namespace hello-helm
pc$ kubectl label namespace hello-helm pod-security.kubernetes.io/enforce=restricted
pc$ helm install hello charts/hello -n hello-helm --wait
```

Dopo l'installazione compare il testo di `NOTES.txt`: istruzioni generate con i nomi reali delle
risorse. Il chart include anche le NetworkPolicy (default deny su tutto il namespace, poi i flussi
consentiti), per cui il namespace deve essere dedicato.

Il release va chiamato `hello`: la configurazione di nginx nel frontend inoltra `/api` a un
Service di nome `hello-backend`, un nome scritto nell'immagine. Rendere configurabile quel nome è
il primo esercizio del capitolo.

**helm test.** Il chart contiene un Pod di test (`templates/tests/test-connection.yaml`) con
l'annotazione `helm.sh/hook: test`: non viene creato all'installazione, ma solo quando lo chiedi.

```bash
pc$ helm test hello -n hello-helm
# Phase: Succeeded  →  backend e frontend rispondono dall'interno del cluster
pc$ kubectl -n hello-helm port-forward svc/hello-frontend 8081:80   # http://localhost:8081
```

Il Pod di test porta l'etichetta `lab.home.arpa/debug: "true"`, che le NetworkPolicy del chart
autorizzano. Senza quell'etichetta il test fallirebbe per timeout: è la default deny che fa il suo
lavoro.

**Un upgrade che riavvia da solo.**

```bash
pc$ helm upgrade hello charts/hello -n hello-helm --set backend.config.GREETING="Ciao, revisione 2" --wait
pc$ kubectl -n hello-helm get pods -l app.kubernetes.io/name=hello-backend   # Pod nuovi: il checksum ha funzionato
pc$ helm history hello -n hello-helm
pc$ helm rollback hello 1 -n hello-helm --wait
```

Nota un dettaglio: con `--set backend.config.GREETING=...` sostituisci solo quella chiave, perché
Helm unisce le mappe in profondità. Le liste invece vengono sostituite per intero.

Quando avrai completato il capitolo 6, potrai esporre questa variante sul Gateway con il file
`values-lab.yaml`, che attiva l'HTTPRoute su `hello-helm.lab.home.arpa`:

```bash
pc$ helm upgrade hello charts/hello -n hello-helm -f charts/hello/values-lab.yaml --wait
```

## 5B.7 Hook e CRD: le due zone delicate

**Hook.** Oltre a `test`, Helm offre hook per ogni fase: `pre-install`, `post-install`,
`pre-upgrade`, `post-upgrade`, `pre-rollback`, `post-rollback`, `pre-delete`, `post-delete`. Una
risorsa con l'annotazione di hook non fa parte del release "normale": viene creata in quel
momento, e `helm.sh/hook-delete-policy` decide quando cancellarla. L'uso tipico è un Job di
migrazione del database prima di un upgrade. Argo CD traduce gli hook di Helm nei propri
(`PreSync`, `PostSync`...), quindi un chart ben scritto funziona con entrambi.

**CRD.** Le CRD messe nella cartella `crds/` di un chart vengono installate alla prima
installazione e poi **mai più aggiornate né cancellate** da Helm. È una scelta di sicurezza:
cancellare una CRD cancella tutti gli oggetti di quel tipo nel cluster (tutti i certificati,
tutte le Application...). La conseguenza pratica è che aggiornare il chart non aggiorna le CRD.
Per questo molti progetti, cert-manager incluso, mettono le CRD tra i template normali dietro un
parametro. Guarda `terraform/01-platform/values/cert-manager.yaml`: `crds.enabled: true` le fa
gestire al chart, `crds.keep: true` impedisce che vengano cancellate con il release. Ora sai
perché quelle due righe ci sono.

## 5B.8 Pacchettizzare e pubblicare

Un chart si distribuisce come archivio versionato. GHCR è anche un registry OCI per chart:

```bash
pc$ helm package charts/hello                          # crea hello-0.1.0.tgz (version del Chart.yaml)
pc$ echo "$GHCR_PAT" | helm registry login ghcr.io -u "$GH_USER" --password-stdin   # solo il dominio
pc$ helm push hello-0.1.0.tgz oci://ghcr.io/$GH_USER/charts
pc$ helm show chart oci://ghcr.io/$GH_USER/charts/hello --version 0.1.0
```

Una versione pubblicata non si ripubblica con contenuto diverso: se cambi il chart, incrementi
`version` in `Chart.yaml`. È la stessa disciplina dei tag immutabili delle immagini (capitolo 4).
In una pipeline matura il chart viene anche **firmato** (Helm supporta i file di provenienza;
molte organizzazioni usano cosign sugli artefatti OCI) e la firma viene verificata prima
dell'installazione.

## 5B.9 Helm o Kustomize?

Non sono alternative esclusive, e un professionista li usa entrambi.

**Helm** dà il meglio quando **distribuisci** software ad altri: un'interfaccia di parametri
documentata e validata, versioni, dipendenze, un ciclo di vita con rollback. Per il software di
terze parti è di fatto lo standard: quasi ogni progetto pubblica un chart.

**Kustomize** dà il meglio quando **personalizzi** le tue configurazioni per più ambienti: niente
linguaggio di template, YAML sempre valido e leggibile, differenze tra ambienti espresse come
patch piccole e revisionabili.

In questo repository la divisione è netta: il software di piattaforma arriva da chart Helm;
l'applicazione è gestita con Kustomize sul percorso principale, e il chart è una seconda forma
dello stesso contenuto, utile per imparare e per distribuirla. In azienda troverai spesso un team
di piattaforma che offre un **chart interno standard** (il "golden path") con probe, sicurezza e
monitoraggio già corretti, che i team applicativi usano fornendo solo i propri valori.

Le due cose si combinano anche: Kustomize può espandere un chart Helm (`helmCharts` in una
kustomization) e applicarci sopra delle patch, e Helm può passare i propri manifest a un
post-renderer (in Helm 4 un plugin) prima di applicarli.

## 5B.10 Helm dentro Terraform e dentro Argo CD

Più avanti incontrerai Helm guidato da altri strumenti, e i due casi si comportano in modo diverso.

**Terraform (`helm_release`, capitolo 9)** usa la libreria di Helm per fare un vero install o
upgrade. Nel cluster esiste un release a tutti gli effetti: `helm list -A` lo mostra, `helm
history` funziona. Ma il proprietario è Terraform: un `helm upgrade` fatto a mano è drift, e il
prossimo `terraform apply` lo annullerà. Il capitolo 9 ha un esercizio proprio su questo.

**Argo CD (capitolo 10)** usa Helm **solo per rendere** i manifest (l'equivalente di `helm
template`) e poi li applica e li riconcilia lui. Nel cluster **non esiste** alcun release Helm:
`helm list` non mostrerà nulla, e `helm rollback` non ha senso. Il rollback si fa in Git. Anche
`lookup`, che interroga il cluster al momento del rendering, in Argo CD restituisce sempre un
risultato vuoto (lo stesso succede con `helm template`: per questo il nostro `NOTES.txt` dice "o
non è verificabile").

Il file `gitops/optional/hello-helm.yaml` è un'Application che installa `charts/hello` tramite
Argo CD. Nota `managedNamespaceMetadata`: siccome il chart non crea il namespace, è Argo CD a
crearlo (`CreateNamespace=true`) con le etichette di Pod Security. Per attivarla, dopo il capitolo
10, disinstalla prima il release manuale (`helm uninstall hello -n hello-helm`), poi sposta il file
in `gitops/apps/`. È l'esercizio 4.

## 5B.11 Troubleshooting di Helm

- **`cannot re-use a name that is still in use`** — un release con quel nome esiste già nel
  namespace (magari in stato `failed`): `helm list -n <ns> -a`. Usa `helm upgrade --install`.
- **`another operation (install/upgrade/rollback) is in progress`** — un'operazione precedente è
  stata interrotta e il release è rimasto `pending-*`. `helm history` mostra la revisione
  bloccata; `helm rollback` all'ultima revisione `deployed` sblocca la situazione.
- **Errore di template con numero di riga** — `helm template --debug` mostra il YAML generato
  fino al punto dell'errore. Quasi sempre è un `nindent` sbagliato o un `{{-` che mangia un a capo
  necessario.
- **`invalid ownership metadata`** — stai installando una risorsa che esiste già e non appartiene
  al release. Helm riconosce i propri oggetti dalle annotazioni `meta.helm.sh/release-name` e
  `meta.helm.sh/release-namespace` e dall'etichetta `app.kubernetes.io/managed-by: Helm`:
  cancella l'oggetto o fallo adottare aggiungendole.
- **Conflitto di proprietà dei campi (Helm 4)** — un altro strumento (kubectl, un controller,
  Argo CD) possiede un campo che il chart vuole cambiare. Prima capisci chi è il proprietario
  legittimo (`kubectl get <risorsa> -o yaml --show-managed-fields`); `--force-conflicts` è
  l'ultima risorsa, non la prima.
- **`--wait` fallisce subito** — con Helm 4 servono permessi `watch` sulle risorse del chart.

## 5B.12 Esercizi

1. **Upstream configurabile.** Rendi configurabile il nome del backend nel frontend: sposta
   `default.conf` di nginx in una ConfigMap generata dal chart (con il nome calcolato da
   `hello.componentName`), montala al posto di quella dell'immagine e aggiungi un checksum anche
   per lei. Poi installa il chart con un nome di release diverso.
2. **Valori per un ambiente di produzione.** Scrivi `values-prod.yaml` con 3 repliche minime,
   risorse più generose e un hostname diverso. Confronta con `helm template` e `diff` l'output
   dei due file di valori.
3. **Pubblicazione in CI.** Aggiungi alla pipeline un job che, sui tag Git `chart-v*`, esegue
   `helm package` e `helm push` su GHCR.
4. **GitOps.** Dopo il capitolo 10, attiva `gitops/optional/hello-helm.yaml` e verifica che
   `helm list -n hello-helm` sia vuoto pur con l'applicazione in funzione. Spiega perché.
5. **Test del chart.** Installa il plugin helm-unittest e scrivi un test che verifichi che, con
   `autoscaling.enabled=true`, il Deployment del backend non contenga il campo `replicas`.

<!-- nav -->
---

[← Capitolo 5 — Il primo deploy](05-primo-deploy.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 6 — Raggiungere l'applicazione dall'esterno →](06-esposizione-esterna.md)
