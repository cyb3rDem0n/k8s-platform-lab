# Capitolo 7 — Sicurezza: rete e runtime

## 7.1 Il modello di rete di default è "tutti parlano con tutti"

Senza NetworkPolicy, ogni Pod può aprire connessioni verso ogni altro Pod del cluster, in
qualunque namespace. Se un attaccante compromette il frontend, da lì può raggiungere il
database, l'API di un altro team, l'LLM. Le **NetworkPolicy** sono il firewall a livello di Pod
che trasforma una rete piatta in una rete segmentata.

Le regole del gioco, che vanno sapute a memoria:

1. Un Pod non selezionato da nessuna policy di un certo tipo (Ingress o Egress) è **aperto** per
   quel tipo.
2. Appena un Pod è selezionato da almeno una policy di tipo Ingress, tutto il traffico in
   ingresso è **vietato** tranne quello esplicitamente consentito. Idem per Egress.
3. Le policy sono **additive**: il consentito è l'unione di tutte le regole che selezionano il
   Pod. Non esistono regole "deny" esplicite nell'API standard.
4. Una connessione consentita consente anche le risposte (le policy sono *stateful*).
5. Le policy le applica il **CNI**. Con un CNI che non le supporta vengono accettate e ignorate.

La trappola di sintassi più famosa riguarda gli elenchi `from`/`to`:

```yaml
# UN elemento con due selettori = AND: Pod "kube-dns" DENTRO il namespace kube-system
- to:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
      podSelector:       { matchLabels: { k8s-app: kube-dns } }

# DUE elementi = OR: qualunque Pod in kube-system, OPPURE Pod "kube-dns" in QUESTO namespace
- to:
    - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } }
    - podSelector:       { matchLabels: { k8s-app: kube-dns } }
```

Un trattino in più cambia completamente il significato. L'etichetta
`kubernetes.io/metadata.name` viene aggiunta automaticamente a ogni namespace ed è il modo
affidabile per selezionarne uno per nome.

## 7.2 Le nostre policy

`k8s/apps/hello/base/network/networkpolicies.yaml` implementa il modello **default deny**:

- `default-deny-all` — seleziona tutti i Pod del namespace, per Ingress ed Egress, senza regole:
  tutto chiuso.
- `allow-dns-egress` — tutti i Pod possono interrogare CoreDNS (UDP e TCP 53). Senza questa
  regola nessun nome si risolve più, ed è il sintomo più comune di una default deny appena
  introdotta.
- `allow-from-gateway` — frontend e backend accettano connessioni sulla 8080 dal namespace
  `nginx-gateway`, dove gira il data plane NGINX.
- `frontend-to-backend` e `frontend-egress-to-backend` — il proxy `/api` del frontend. Servono
  **due** regole: l'uscita dal frontend e l'ingresso nel backend. Con la default deny su entrambi
  i lati, una sola non basta.
- `backend-egress-to-llm` — il backend può uscire solo verso Ollama nel namespace `ai`.
- `allow-metrics-scrape` — Prometheus, dal namespace `monitoring`, può leggere `/metrics`.
- `allow-debug-pods-*` — i Pod con l'etichetta `lab.home.arpa/debug=true` possono raggiungere
  frontend e backend, per i test.

Nota che le porte nelle policy sono quelle **dei Pod** (8080), non quelle dei Service (80): le
policy vedono il traffico dopo la traduzione di kube-proxy.

## 7.3 Applicare e verificare

Prima di applicare, fotografa lo stato attuale con un Pod di test:

```bash
pc$ kubectl apply -f k8s/learn/01-pod-debug.yaml
pc$ kubectl -n hello exec netshoot -- curl -s -m 3 hello-backend:8080/api/hello
pc$ kubectl -n hello exec netshoot -- curl -s -m 3 https://example.com -o /dev/null -w '%{http_code}\n'
```

Entrambe funzionano. Applica le policy e ripeti:

```bash
pc$ kubectl apply -k k8s/apps/hello/base/network
pc$ kubectl -n hello get networkpolicy
pc$ kubectl -n hello exec netshoot -- curl -s -m 3 hello-backend:8080/api/hello     # OK: consentito
pc$ kubectl -n hello exec netshoot -- curl -s -m 3 https://example.com              # timeout: Internet chiuso
pc$ scripts/smoke-test.sh                                                           # il Gateway funziona
```

Ora l'esercizio chiave. Riapplica il NodePort del capitolo 6 e prova:

```bash
pc$ kubectl apply -f k8s/learn/02-frontend-nodeport.yaml
pc$ curl -m 5 http://192.168.1.50:30080/        # timeout
```

**Perché?** Ragionaci prima di leggere. Il traffico dal NodePort arriva ai Pod del frontend con
un IP sorgente che non appartiene al namespace `nginx-gateway`: nessuna regola lo consente e la
default deny lo scarta. Il Gateway invece funziona, perché i suoi Pod stanno proprio in
`nginx-gateway`. Con le policy, l'**unico ingresso** all'applicazione è il Gateway: è
esattamente ciò che volevamo. Rimuovi il NodePort e il Pod di debug quando hai finito.

Una nota: `kubectl port-forward` di solito continua a funzionare anche con la default deny,
perché la connessione entra nel Pod dalla sua interfaccia di loopback e non attraversa la rete
dei Pod. È un altro motivo per cui il permesso di fare port-forward va concesso con attenzione
tramite RBAC.

## 7.4 Pod Security, ripasso operativo

Hai già visto `restricted` all'opera. Prima di irrigidire un namespace esistente, puoi chiedere
all'API server quali Pod attuali violerebbero il nuovo profilo, senza cambiare nulla:

```bash
pc$ kubectl label --dry-run=server --overwrite namespace ai pod-security.kubernetes.io/enforce=restricted
```

L'output elenca le violazioni Pod per Pod. È il modo sicuro di migrare un namespace da
`baseline` a `restricted`.

## 7.5 RBAC: chi può fare cosa

L'API server autorizza ogni richiesta con **RBAC**. Gli oggetti sono quattro: **Role** (permessi
in un namespace) e **ClusterRole** (permessi su tutto il cluster o su risorse non namespaced),
collegati a utenti, gruppi o ServiceAccount da **RoleBinding** e **ClusterRoleBinding**. Un
permesso è una combinazione di gruppo API, risorsa e verbo (`get`, `list`, `watch`, `create`,
`update`, `patch`, `delete`). Non esistono permessi negativi: tutto ciò che non è concesso è
negato.

Kubernetes fornisce ClusterRole predefiniti pensati per essere riusati: `view` (lettura, esclusi
i Secret), `edit` (modifica, senza RBAC), `admin` (tutto in un namespace), `cluster-admin`
(tutto). Per verificare:

```bash
pc$ kubectl auth can-i list secrets -n hello --as system:serviceaccount:ai:ai-agent-readonly   # no
pc$ kubectl auth can-i list pods    -n hello --as system:serviceaccount:ai:ai-agent-readonly   # yes (dopo il cap. 12)
pc$ kubectl auth can-i --list --as system:serviceaccount:hello:hello-backend -n hello
```

Il file `admin.conf` che usi è **cluster-admin**: non condividerlo e non darlo a strumenti
automatici. Per un secondo utente umano: `kubeadm kubeconfig user --client-name=<nome>` sul
control plane, più un RoleBinding. Per gli strumenti: ServiceAccount con il minimo necessario,
come vedremo per gli agenti AI.

## 7.6 Oltre: supply chain e policy di ammissione

Due passi successivi che un team di piattaforma maturo compie:

**Scansione delle immagini.** `trivy image ghcr.io/<tu>/k8s-platform-lab-backend:0.1.0` elenca le
vulnerabilità note. L'immagine distroless con jlink ne avrà pochissime; prova per confronto
un'immagine basata su una distribuzione completa. La scansione va messa nella CI, bloccando le
vulnerabilità critiche.

**Policy di ammissione.** Le **ValidatingAdmissionPolicy** (stabili da Kubernetes 1.30)
permettono di scrivere regole in CEL, valutate dall'API server stesso, senza installare nulla.
Esempio: vietare i tag `:latest` nel namespace `hello`.

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: no-latest-tag
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
      - apiGroups: ["apps"]
        apiVersions: ["v1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["deployments"]
  validations:
    - expression: >-
        object.spec.template.spec.containers.all(c,
          c.image.contains(':') && !c.image.endsWith(':latest'))
      message: "Usa un tag immutabile: niente :latest e niente immagini senza tag."
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata:
  name: no-latest-tag-hello
spec:
  policyName: no-latest-tag
  validationActions: ["Deny"]
  matchResources:
    namespaceSelector:
      matchLabels: { kubernetes.io/metadata.name: hello }
```

Per esigenze più ricche (generare o modificare risorse, verificare firme delle immagini) si usano
Kyverno o OPA Gatekeeper.

## 7.7 Esercizi

1. Scrivi le NetworkPolicy per il namespace `ai` in modo che Ollama possa uscire **solo** verso
   il registro dei modelli (servono DNS e HTTPS in uscita; con le policy standard non puoi
   filtrare per nome di dominio: perché? Cosa offrono in più le policy di Calico o Cilium?).
2. Applica la ValidatingAdmissionPolicy e prova `kubectl -n hello set image deploy/hello-frontend
   nginx=nginx:latest`. Dove compare l'errore?
3. Verifica con `kubectl auth can-i` che il ServiceAccount `hello-backend` non possa fare nulla
   sull'API.

<!-- nav -->
---

[← Capitolo 6 — Raggiungere l'applicazione dall'esterno](06-esposizione-esterna.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 8 — Scalabilità e resilienza →](08-scalabilita-resilienza.md)
