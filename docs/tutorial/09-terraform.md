# Capitolo 9 — Terraform: la piattaforma come codice

## 9.1 A cosa serve Terraform se abbiamo già Ansible e Helm

Ansible configura macchine: esegue passi su host esistenti, e non conserva memoria di cosa ha
creato. **Terraform** crea e gestisce **risorse** tramite le API dei fornitori (cloud, DNS,
Kubernetes, Helm, GitHub...), e mantiene uno **stato** che registra ogni risorsa che possiede.
Grazie allo stato può calcolare in anticipo cosa cambierà (`plan`), cancellare ciò che non è più
dichiarato e accorgersi quando qualcuno ha modificato le cose a mano (**drift**).

Nel nostro laboratorio Terraform installa la piattaforma nel cluster. Nella parte cloud creerà
anche il cluster stesso, la rete, i load balancer, i permessi: è lì che darà il meglio. Imparare
qui, su un cluster che puoi distruggere senza costi, ti prepara a quel passo.

## 9.2 I concetti fondamentali

- **Provider** — un plugin che traduce le risorse Terraform in chiamate API. Usiamo `helm` e
  `kubernetes`, entrambi alla versione principale 3.
- **Resource** — un oggetto che Terraform crea e gestisce (`helm_release.metallb`).
- **Variable** e **output** — ingressi e uscite di una configurazione.
- **State** — il file `terraform.tfstate`: per ogni risorsa, il suo identificativo reale e gli
  attributi noti. È la memoria di Terraform.
- **Plan** — il confronto tra configurazione, stato e mondo reale, con l'elenco delle azioni
  (`+` crea, `~` modifica, `-` distruggi, `-/+` sostituisci).
- **Grafo delle dipendenze** — Terraform ordina le operazioni dai riferimenti tra risorse
  (dipendenze implicite) e da `depends_on` (esplicite), ed esegue in parallelo ciò che è
  indipendente.

Lo stato merita attenzione. Può contenere dati sensibili (valori passati ai chart, password
generate), quindi **non va mai in Git**: il `.gitignore` lo esclude. Nel laboratorio è locale; in
un team vive in un **backend remoto** con **lock**, perché due `apply` concorrenti sullo stesso
stato lo corromperebbero. Nella parte cloud useremo S3, GCS e Azure Storage. Il file
`.terraform.lock.hcl`, invece, **va** committato: registra le versioni esatte e i checksum dei
provider, esattamente come un lock file di npm o Maven.

## 9.3 Perché due stadi

Il provider `kubernetes`, per la risorsa `kubernetes_manifest`, legge lo schema del tipo
dall'API server **al momento del plan**. Se nello stesso piano installi cert-manager (che porta
la CRD `ClusterIssuer`) e crei un `ClusterIssuer`, il plan fallisce: quando viene calcolato, la
CRD non esiste ancora. È uno dei problemi più noti dell'uso di Terraform con Kubernetes.

Le soluzioni possibili sono tre: separare in due configurazioni applicate in sequenza (la nostra
scelta: esplicita e didattica); usare un provider che rimanda la validazione all'apply (come
`alekc/kubectl`); oppure lasciare quegli oggetti a Argo CD. Tutte e tre sono usate in
produzione. Con due stadi:

- `terraform/01-platform` installa controller e CRD: CRD del Gateway API, local-path-provisioner,
  metrics-server, MetalLB, cert-manager, NGINX Gateway Fabric, Argo CD;
- `terraform/02-platform-config` crea gli oggetti che usano quelle CRD: pool di MetalLB, PKI,
  Gateway, route di Argo CD e, quando lo abiliti, il progetto e l'Application radice di Argo CD.

## 9.4 Lettura guidata dello stadio 01

**`versions.tf`** — vincola la versione di Terraform e dei provider con `~> 3.0` (qualunque 3.x,
mai 4.0: le versioni principali possono rompere la compatibilità). Il provider Helm 3 ha cambiato
sintassi rispetto al 2: il blocco `kubernetes { ... }` è diventato un attributo `kubernetes = {
... }`, e `set` è diventato una lista di oggetti. Molti esempi online sono ancora nella vecchia
forma: riconoscerla ti farà risparmiare tempo.

**`variables.tf`** — tutte le versioni in un unico oggetto `versions`. Aggiornare un componente
significa cambiare una riga, in un commit dedicato, dopo aver letto il changelog.
`scripts/check-versions.sh` segnala cosa è aggiornabile ma non aggiorna niente da solo.

**`terraform_data` con `local-exec`** per le CRD del Gateway API e per local-path-provisioner:
non sono chart Helm, sono manifest pubblicati come file. È un compromesso consapevole: è
semplice, ma Terraform non traccia gli oggetti creati (non li cancellerà con `destroy`) e serve
`kubectl` sulla macchina che esegue. `triggers_replace` fa rieseguire il comando quando cambia la
versione.

**`kubernetes_namespace_v1.metallb`** — creiamo noi il namespace di MetalLB per poterlo
etichettare `privileged`. `create_namespace` di Helm non permette di aggiungere etichette.

**`helm_release`** (il ciclo di vita dei release è spiegato nel capitolo 5B) — ogni chart ha versione bloccata e valori in un **file YAML** separato in
`values/`. *Perché file e non `set`:* i file si leggono, si revisionano e si confrontano con la
documentazione del chart; decine di `set` in HCL diventano illeggibili. `wait = true` fa
attendere a Terraform che le risorse del chart siano pronte prima di proseguire.

**`depends_on`** — cert-manager deve partire dopo le CRD del Gateway API (le cerca all'avvio per
attivare il relativo controller); NGF dopo le CRD e dopo MetalLB (il suo Service ha bisogno di
un IP). Sono dipendenze che Terraform non potrebbe dedurre da solo, perché non ci sono riferimenti
tra le risorse.

**`values/argocd.yaml.tftpl`** — un template: il dominio di Argo CD viene dalla variabile
`base_domain`. `server.insecure: true` perché il TLS è terminato dal Gateway e argocd-server
parla HTTP dentro il cluster. `timeout.reconciliation: 60s` accorcia il polling di Git (il
default è tre minuti).

## 9.5 Lettura guidata dello stadio 02

```hcl
m = { for f in fileset("${path.module}/manifests", "*.yaml") :
  trimsuffix(f, ".yaml") => yamldecode(templatefile("${path.module}/manifests/${f}", local.tpl_vars))
}
```

Legge tutti i file della cartella `manifests/`, sostituisce le variabili con `templatefile` e
converte lo YAML in oggetti HCL con `yamldecode`. Ogni risorsa `kubernetes_manifest` prende il
suo oggetto dalla mappa. Il vantaggio: i manifest restano YAML leggibili (li hai applicati a mano
nel capitolo 6), Terraform aggiunge solo parametri, ordine e stato.

Il blocco `wait { condition { type = "Ready" status = "True" } }` sul certificato della CA fa
attendere a Terraform che cert-manager abbia davvero emesso la radice, prima di creare
l'emettitore che la usa.

`count = var.enable_gitops ? 1 : 0` rende opzionali progetto e Application radice di Argo CD:
restano spenti finché non arrivi al capitolo 10.

## 9.6 Dal manuale al codice: ricostruire

Il cluster ora contiene componenti installati a mano nei capitoli 6 e 8. Se lanciassi
Terraform così com'è, proverebbe a installarli una seconda volta e fallirebbe con errori di
conflitto. Hai due strade.

**Strada A, consigliata: ricostruire da zero.** È anche la prova definitiva che tutto è
riproducibile.

```bash
pc$ cd ansible && ansible-playbook reset.yml -e confirm=yes && ansible-playbook site.yml && cd ..
pc$ cp terraform/01-platform/terraform.tfvars.example terraform/01-platform/terraform.tfvars
pc$ cp terraform/02-platform-config/terraform.tfvars.example terraform/02-platform-config/terraform.tfvars
pc$ $EDITOR terraform/02-platform-config/terraform.tfvars     # il tuo range di IP per MetalLB
```

**Strada B: importare.** Terraform può prendere in carico risorse esistenti. Con i blocchi
`import` (Terraform ≥ 1.5) dichiari cosa importare direttamente nel codice:

```hcl
import {
  to = helm_release.metallb
  id = "metallb-system/metallb"            # namespace/nome del release
}
import {
  to = kubernetes_manifest.gateway
  id = "apiVersion=gateway.networking.k8s.io/v1,kind=Gateway,namespace=nginx-gateway,name=lab-gateway"
}
```

`terraform plan` mostrerà le importazioni e le eventuali differenze. In un'azienda è la strada
quotidiana, perché non si distrugge la produzione per adottare Terraform. Nel laboratorio,
ricostruire insegna di più con meno fatica.

## 9.7 Applicare

```bash
pc$ cd terraform/01-platform
pc$ terraform init            # scarica i provider, crea .terraform.lock.hcl (committalo)
pc$ terraform fmt -check && terraform validate
pc$ terraform plan            # LEGGILO: è l'abitudine più importante di chi usa Terraform
pc$ terraform apply
pc$ cd ../02-platform-config && terraform init && terraform apply
pc$ terraform output hosts_entries
```

Oppure `make platform` e `make platform-config`. Poi riapplica l'applicazione, che per ora
gestiamo ancora con kubectl:

```bash
pc$ kubectl apply -k k8s/learn/stage-05-core
pc$ kubectl apply -k k8s/apps/hello/base/routing
pc$ kubectl apply -k k8s/apps/hello/base/network
pc$ scripts/smoke-test.sh
```

L'IP del Gateway è cambiato? Aggiorna `/etc/hosts`. Anche la CA è nuova: esporta di nuovo
`lab-root-ca.crt` e sostituisci la vecchia nel sistema. Ricostruire una PKI significa
ridistribuire la fiducia; in produzione la CA radice sopravvive ai cluster e vive fuori da essi.

## 9.8 Esercizio sul drift

```bash
pc$ helm -n metallb-system upgrade metallb metallb/metallb --version 0.15.2 \
      --reuse-values --set controller.logLevel=debug
pc$ cd terraform/01-platform && terraform plan
```

Il plan mostra che `helm_release.metallb` diverge dalla configurazione e propone di riportarlo
com'era. Chi ha ragione? **Il codice**: la modifica manuale va o annullata con `apply`, o
riportata nel file di valori con un commit. Qualunque altra scelta rende il codice una
descrizione infedele del sistema. `terraform plan -refresh-only` mostra solo le differenze tra
stato e realtà, senza proporre modifiche alla configurazione.

## 9.9 Buone pratiche

- `terraform fmt` e `terraform validate` sempre, in CI (il nostro workflow lo fa).
- Versioni dei provider vincolate e lock file committato.
- Mai segreti nei file `.tfvars` in Git; nel cloud li leggeremo da un secret manager.
- Stato remoto con lock appena si lavora in più di uno, o da più macchine.
- In CI: `plan` su ogni pull request, `apply` solo dopo la revisione e il merge.
- Configurazioni piccole e separate per ciclo di vita (la rete cambia raramente, le app spesso)
  invece di un'unica configurazione enorme: piani più veloci e danni contenuti.

## 9.10 Esercizi

1. Aggiungi un blocco `validation` alla variabile `metallb_address_range` che rifiuti valori
   senza il trattino.
2. Aggiungi un blocco `check` (Terraform ≥ 1.5) che, dopo l'apply, verifichi con una data source
   `http` che `https://hello.<base_domain>/healthz` risponda.
3. Trasforma lo stadio 01 in un modulo riutilizzabile con input `versions` e `values_dir`: sarà
   la base per i cluster cloud.

<!-- nav -->
---

[← Capitolo 8 — Scalabilità e resilienza](08-scalabilita-resilienza.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 10 — GitOps con Argo CD →](10-gitops-argocd.md)
