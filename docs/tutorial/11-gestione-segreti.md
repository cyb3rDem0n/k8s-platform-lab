# Capitolo 11 — Gestione dei segreti

## 11.1 Il problema, detto senza giri di parole

Un `Secret` di Kubernetes non è segreto. Guarda:

```bash
pc$ kubectl -n hello create secret generic demo --from-literal=password=supersegreta
pc$ kubectl -n hello get secret demo -o jsonpath='{.data.password}'
c3VwZXJzZWdyZXRh
pc$ echo c3VwZXJzZWdyZXRh | base64 -d
supersegreta
pc$ kubectl -n hello delete secret demo
```

Base64 è una **codifica**, non una cifratura: serve a trasportare byte arbitrari dentro YAML,
non a nasconderli. Chiunque possa leggere il Secret (via RBAC) o il file YAML (via Git) ha il
valore in chiaro.

I rischi reali sono tre, e ognuno ha una contromisura diversa:

1. **Il segreto finisce in Git.** È il rischio più comune e più grave: la storia di Git è per
   sempre, i fork la copiano, e scanner automatici cercano credenziali nei repository pubblici
   in pochi minuti. Contromisura: in Git va solo materiale cifrato, o solo un *riferimento* al
   segreto.
2. **Il segreto è leggibile nel cluster da chi non dovrebbe.** Contromisura: RBAC. Il ClusterRole
   predefinito `view` esclude di proposito i Secret; il nostro ServiceAccount per agenti AI
   (capitolo 12) si basa proprio su questo.
3. **Il segreto è in chiaro su disco, in etcd.** Chi ottiene un backup di etcd o l'accesso al
   disco del control plane legge tutto. Contromisura: cifratura a riposo di etcd (sezione 11.7).

GitOps rende il punto 1 urgente: se Git è la fonte di verità e contiene tutto, come ci metti le
password? Le risposte possibili si dividono in due famiglie.

## 11.2 Le due famiglie di soluzioni

**Segreti cifrati dentro Git.** Il valore sta nel repository, ma cifrato con una chiave che solo
il cluster (o solo chi è autorizzato) possiede. Git resta davvero l'unica fonte di verità.

- **Sealed Secrets** — un controller nel cluster possiede una coppia di chiavi asimmetriche.
  Tu cifri con la chiave pubblica (strumento `kubeseal`), committi l'oggetto `SealedSecret`, il
  controller lo decifra e crea il `Secret` normale.
- **SOPS** (con age, PGP o un KMS cloud) — cifra i *valori* dentro file YAML lasciando leggibili
  le chiavi. Flux lo supporta nativamente; con Argo CD serve un plugin (es. KSOPS o helm-secrets).

**Riferimenti dentro Git, valori in un gestore esterno.** In Git c'è solo "prendi il segreto X
dal vault Y"; il valore vive in un sistema dedicato con audit, rotazione e controllo degli accessi.

- **External Secrets Operator (ESO)** — un controller che legge da HashiCorp Vault, OpenBao
  (il fork open source di Vault), AWS Secrets Manager, Google Secret Manager, Azure Key Vault
  e molti altri, e sincronizza il valore in un `Secret` Kubernetes.
- **Secrets Store CSI Driver** — monta i segreti come file direttamente nel Pod tramite un
  volume, senza necessariamente creare un oggetto `Secret`.

Come scegliere? Senza un gestore esterno già disponibile (il nostro caso sul NUC), Sealed
Secrets è la soluzione più semplice che resta corretta. Nel cloud, dove esiste già un secret
manager gestito con IAM, ESO è quasi sempre la scelta migliore: rotazione centralizzata, audit,
nessuna chiave privata del cluster da proteggere. Il capitolo 15 fa esattamente questo passaggio.

## 11.3 Come funziona Sealed Secrets

```
  pc$ kubeseal (chiave PUBBLICA)                  cluster: controller (chiave PRIVATA)
  ┌────────────┐   cifra   ┌──────────────┐  git   ┌──────────────┐ decifra ┌────────┐
  │ Secret     │ ────────► │ SealedSecret │ ─────► │ SealedSecret │ ──────► │ Secret │
  │ (in chiaro,│           │ (cifrato,    │ ArgoCD │              │         │        │
  │  solo RAM) │           │  committabile)│       └──────────────┘         └────────┘
  └────────────┘           └──────────────┘
```

Dettagli che contano:

- Al primo avvio il controller genera una coppia di chiavi **RSA a 4096 bit** e la salva come
  Secret in `kube-system`, con l'etichetta `sealedsecrets.bitnami.com/sealed-secrets-key`.
- Ogni valore è cifrato con una chiave simmetrica casuale (AES‑GCM), e solo quella chiave è
  cifrata con RSA: cifratura ibrida, lo stesso schema di TLS e PGP.
- **Scope.** Per default (`strict`) il nome e il namespace del Secret fanno parte dei dati
  cifrati: non puoi copiare un SealedSecret in un altro namespace o rinominarlo per farti
  decifrare il valore. Esistono gli scope `namespace-wide` e `cluster-wide`, più permissivi.
- **Rinnovo delle chiavi.** Ogni 30 giorni il controller genera una nuova coppia e cifra i
  *nuovi* segreti con quella; le vecchie restano per decifrare i SealedSecret esistenti. Il
  rinnovo non ri-cifra nulla da solo: per ruotare davvero, devi ri-sigillare (e, soprattutto,
  cambiare il valore del segreto).
- **La chiave privata è il punto critico.** Se ricostruisci il cluster da zero senza averla
  salvata, il nuovo controller genera nuove chiavi e **nessun SealedSecret in Git è più
  decifrabile**. Il backup della chiave è obbligatorio (11.6).

## 11.4 Installazione

Il controller è già dichiarato in `gitops/apps/sealed-secrets.yaml`, con sync wave `-1` perché
deve esistere prima delle applicazioni che usano SealedSecret. Se hai completato il capitolo 10
è già in esecuzione:

```bash
pc$ kubectl -n kube-system get deploy sealed-secrets-controller
pc$ kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key
```

Installa la CLI sulla tua macchina (scegli la versione corrispondente al controller dalla pagina
delle release di `bitnami-labs/sealed-secrets`), poi verifica che raggiunga il controller:

```bash
pc$ kubeseal --controller-name sealed-secrets-controller \
             --controller-namespace kube-system --fetch-cert > /tmp/sealed-secrets-pub.pem
pc$ openssl x509 -in /tmp/sealed-secrets-pub.pem -noout -subject -enddate
```

Il certificato pubblico si può condividere liberamente: permette di cifrare, non di decifrare.
Salvarlo consente di sigillare segreti anche senza accesso al cluster (`kubeseal --cert`), ad
esempio in una pipeline.

## 11.5 Pratica: il token del backend

Il backend legge `API_TOKEN` da un Secret opzionale (`secretKeyRef.optional: true`): senza
Secret parte comunque e `/api/ask` risponde 503. Ora creiamo il Secret nel modo corretto.

```bash
pc$ scripts/seal-backend-secret.sh
Creato k8s/apps/hello/overlays/lab/sealed-backend-secret.yaml (cifrato: si può committare).
Token in chiaro (salvalo nel tuo password manager, NON in Git): 3f9c...
```

Leggi lo script: il Secret in chiaro viene generato con `--dry-run=client -o yaml` e passato
via pipe a `kubeseal`. **Non tocca mai il disco.** Apri il file prodotto: vedrai `encryptedData`
con blob illeggibili, e nome e namespace in chiaro.

Poi attivalo nell'overlay e lascia lavorare GitOps:

```bash
pc$ sed -i 's|  # - sealed-backend-secret.yaml.*|  - sealed-backend-secret.yaml|' \
      k8s/apps/hello/overlays/lab/kustomization.yaml
pc$ git add k8s/apps/hello/overlays/lab && git commit -m "feat(hello): api token sigillato" && git push
```

**Verifica:**

```bash
pc$ kubectl -n hello get sealedsecret,secret hello-backend-secret
pc$ kubectl -n hello get sealedsecret hello-backend-secret -o jsonpath='{.status.conditions}'  # Synced=True
pc$ curl -s --cacert lab-root-ca.crt https://hello.lab.home.arpa/api/info   # "apiTokenConfigured": true
```

Se `apiTokenConfigured` resta `false`: le variabili d'ambiente si leggono **solo all'avvio del
container**. Un Secret creato dopo non viene visto dai Pod già in esecuzione. Riavviali:

```bash
pc$ kubectl -n hello rollout restart deploy/hello-backend
```

In un sistema maturo questo si automatizza: o montando il Secret come file (i file si aggiornano
da soli, ma l'applicazione deve rileggerli), o con un controller come Stakater Reloader che
riavvia i Deployment quando un Secret referenziato cambia, o aggiungendo all'annotazione del
template un hash del contenuto.

## 11.6 Backup della chiave privata

Fallo adesso, non "dopo":

```bash
pc$ kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
      -o yaml > sealed-secrets-master.key
```

Questo file **decifra tutti i tuoi segreti**. Va in un password manager o in un archivio
cifrato, fuori dal repository (`*.key` è già in `.gitignore`), e idealmente in due posti.

Il ripristino avviene **prima** che Argo CD sincronizzi i SealedSecret su un cluster nuovo:

```bash
pc$ kubectl apply -f sealed-secrets-master.key
pc$ kubectl -n kube-system delete pod -l app.kubernetes.io/name=sealed-secrets
```

Il controller riparte, trova le chiavi esistenti e le usa. L'ordine completo del disaster
recovery è nel capitolo 14.

## 11.7 Rotazione

Ruotare un segreto significa **cambiarne il valore**, non ri-cifrarlo. Il flusso:

1. Genera un nuovo valore e sigillalo (`API_TOKEN=... scripts/seal-backend-secret.sh`, oppure
   lascia che lo script ne generi uno).
2. Commit e push: Argo CD aggiorna il Secret.
3. `rollout restart` del backend.
4. Aggiorna i client che usano il vecchio token.

Se un token è compromesso, ri-sigillare lo **stesso** valore non serve a nulla: il valore
vecchio è ancora valido ed è nella storia di Git cifrato con una chiave che il cluster conosce.

## 11.8 Cifratura a riposo di etcd (avanzato)

Sealed Secrets protegge Git. In etcd, però, il `Secret` generato è ancora solo base64. Kubernetes
può cifrare le risorse prima di scriverle in etcd tramite una `EncryptionConfiguration`.

```bash
nuc$ sudo mkdir -p /etc/kubernetes/enc
nuc$ KEY=$(head -c 32 /dev/urandom | base64)
nuc$ sudo tee /etc/kubernetes/enc/enc.yaml >/dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${KEY}
      - identity: {}        # permette di leggere i dati scritti prima della cifratura
EOF
nuc$ sudo chmod 600 /etc/kubernetes/enc/enc.yaml
```

Poi modifica il manifest statico `/etc/kubernetes/manifests/kube-apiserver.yaml`: aggiungi il
flag `--encryption-provider-config=/etc/kubernetes/enc/enc.yaml`, un `volume` di tipo
`hostPath` che punta a `/etc/kubernetes/enc` e il relativo `volumeMount` in sola lettura. Il
kubelet vede il file cambiato e riavvia l'API server da solo (fai prima una copia del manifest
**fuori** dalla cartella `manifests`, altrimenti verrebbe avviata anche la copia).

I Secret esistenti restano in chiaro finché non vengono riscritti:

```bash
pc$ kubectl get secrets -A -o json | kubectl replace -f -
```

Due considerazioni da professionista. Primo: la chiave sta sullo stesso disco di etcd, quindi
questa configurazione protegge soprattutto i **backup** di etcd copiati altrove. La protezione
completa richiede il provider **KMS v2**, che affida la chiave a un servizio esterno (Vault,
KMS del cloud): nei cluster gestiti del cloud è un'opzione da attivare, e la vedremo lì. Secondo:
questa modifica non è gestita da Ansible nel repository; aggiungerla come ruolo è l'esercizio 3.

## 11.9 Uno sguardo a External Secrets Operator

Per chiudere il cerchio con il cloud, ecco come apparirà lo stesso segreto con ESO e AWS Secrets
Manager. Non va applicato ora, serve a vedere la differenza di modello:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: hello-backend-secret
  namespace: hello
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager      # configurato una volta dal team piattaforma, con identità IAM
  target:
    name: hello-backend-secret     # il Secret Kubernetes che ESO crea e mantiene
  data:
    - secretKey: API_TOKEN
      remoteRef:
        key: k8s-platform-lab/hello-backend
        property: API_TOKEN
```

In Git non c'è nessun valore, nemmeno cifrato. La rotazione avviene nel secret manager, e ESO
propaga il nuovo valore entro `refreshInterval`. Il costo è un sistema in più da gestire e una
dipendenza a runtime: se il secret manager non è raggiungibile, i nuovi Secret non si creano.

## 11.10 Esercizi

1. Porta la password di Grafana (`gitops/optional/monitoring.yaml`) in un SealedSecret e usa
   `grafana.admin.existingSecret` nei valori del chart.
2. Prova lo scope: copia il file del SealedSecret cambiando `namespace` in `default`,
   applicalo e leggi l'errore del controller. Spiega perché è una protezione.
3. Scrivi un ruolo Ansible `etcd_encryption` che automatizza la sezione 11.8 in modo idempotente.
4. Simula il disastro: salva la chiave, cancella il Secret della chiave e il Pod del controller,
   osserva che i SealedSecret non si decifrano più, poi ripristina.

<!-- nav -->
---

[← Capitolo 10 — GitOps con Argo CD](10-gitops-argocd.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 12 — Strumenti AI nel cluster e attorno al cluster →](12-strumenti-ai.md)
