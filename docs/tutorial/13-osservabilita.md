# Capitolo 13 — Osservabilità

## 13.1 I tre segnali

Monitorare significa rispondere a domande su un sistema senza doverlo modificare. Le risposte
arrivano da tre tipi di segnale:

- **Metriche** — numeri nel tempo (richieste al secondo, latenza, memoria). Economiche da
  conservare, ideali per allarmi e trend. Lo strumento di riferimento è **Prometheus**.
- **Log** — eventi testuali. Dicono *cosa* è successo a una singola richiesta. In Kubernetes le
  applicazioni scrivono su stdout e la piattaforma li raccoglie (il nostro backend fa esattamente
  questo). Stack tipico: Loki o Elasticsearch/OpenSearch.
- **Tracce** — il percorso di una singola richiesta attraverso più servizi, con i tempi di ogni
  tratto. Standard: **OpenTelemetry**. Backend: Tempo, Jaeger.

In questo capitolo installiamo le metriche, che danno il ritorno più alto con lo sforzo minore.
Log e tracce sono esercizi e, nel cloud, servizi gestiti.

## 13.2 Come funziona Prometheus

Prometheus usa un modello **pull**: a intervalli regolari interroga (fa *scrape*) un endpoint
HTTP di ogni target, di solito `/metrics`, e salva i campioni nel suo database a serie temporali.
Ogni serie è identificata da un nome e da un insieme di etichette:

```
hello_http_requests_total{path="/api/hello",status="200"} 1523
```

I tipi di metrica principali: **counter** (cresce sempre, si azzera solo al riavvio: richieste,
errori), **gauge** (sale e scende: memoria, code, `hello_ready`), **histogram** (distribuzione
in bucket: latenze, da cui si calcolano i percentili).

In Kubernetes i target cambiano continuamente, quindi nessuno li elenca a mano. Il
**Prometheus Operator** introduce CRD come `ServiceMonitor` e `PodMonitor`: dichiari "fai scrape
dei Service con queste etichette, su questa porta" e l'operatore genera la configurazione di
Prometheus. È lo stesso modello dichiarativo del resto del corso.

**kube-prometheus-stack** è il chart Helm che installa tutto insieme: operatore, Prometheus,
Alertmanager, Grafana, node-exporter (metriche del sistema operativo), kube-state-metrics
(metriche sullo *stato* degli oggetti Kubernetes: repliche desiderate e disponibili, Pod per
fase, restart), più dashboard e regole di allarme già pronte.

Attenzione a non confondere **metrics-server** (capitolo 8) con Prometheus: metrics-server tiene
solo l'ultimo valore di CPU e memoria in RAM, per `kubectl top` e per l'HPA; Prometheus conserva
la storia e qualunque metrica applicativa.

## 13.3 Installare lo stack via GitOps

Lo stack è già dichiarato in `gitops/optional/monitoring.yaml`, spento. Richiede circa 1,5 GB di
RAM. Prima di attivarlo:

1. Scegli la versione del chart: `scripts/check-versions.sh` mostra l'ultima; sostituisci
   `CHANGE_ME` in `targetRevision`. Una versione bloccata è la regola in tutto il repository:
   "l'ultima" cambia sotto i piedi e rende i sync non riproducibili.
2. Nota le scelte nei valori: retention di 7 giorni, i componenti del control plane
   (`kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, `kubeProxy`) disattivati perché con
   kubeadm ascoltano solo su localhost e genererebbero allarmi falsi, `ServerSideApply=true`
   perché le CRD dell'operatore superano il limite di dimensione dell'apply lato client.

Poi attivalo con un commit:

```bash
pc$ git mv gitops/optional/monitoring.yaml gitops/apps/monitoring.yaml
pc$ git commit -m "feat(platform): kube-prometheus-stack" && git push
pc$ kubectl -n monitoring get pods -w          # qualche minuto
```

## 13.4 Collegare il backend: il componente Kustomize

Il backend espone `/metrics` in formato Prometheus (`Metrics.java`, scritto a mano, senza
librerie). Per dire a Prometheus di leggerlo serve un `ServiceMonitor`, ma quel tipo esiste solo
dopo l'installazione dello stack: se fosse nella base, la base smetterebbe di funzionare su un
cluster senza monitoring.

La soluzione è un **Component** di Kustomize (`k8s/apps/hello/components/monitoring/`): un
pezzo opzionale che un overlay include o no. Attivalo nell'overlay `lab`:

```bash
pc$ sed -i 's|^# components:|components:|; s|^#   - ../../components/monitoring.*|  - ../../components/monitoring|' \
      k8s/apps/hello/overlays/lab/kustomization.yaml
pc$ kubectl kustomize k8s/apps/hello/overlays/lab | grep -A3 'kind: ServiceMonitor'
pc$ git commit -am "feat(hello): ServiceMonitor" && git push
```

Il ServiceMonitor ha l'etichetta `release: kube-prometheus-stack`: è il selettore che l'istanza
Prometheus del chart usa per default per scegliere quali ServiceMonitor leggere. Senza quella
etichetta, il ServiceMonitor esiste ma viene ignorato: è l'errore più comune in assoluto.

Serve anche la rete: la NetworkPolicy `allow-metrics-scrape` del capitolo 7 ammette già il
traffico dal namespace `monitoring` verso la porta 8080 del backend. Se l'avessi dimenticata,
il target risulterebbe `down` con un timeout, e ora sapresti perché.

**Verifica:**

```bash
pc$ kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
# http://localhost:9090 → Status → Targets: serviceMonitor/hello/hello-backend, 2/2 up
```

## 13.5 PromQL essenziale

Genera un po' di traffico (`for i in $(seq 200); do curl -s --cacert lab-root-ca.crt https://hello.lab.home.arpa/api/hello >/dev/null; done`)
e prova queste query nella pagina Graph di Prometheus:

```promql
# Richieste al secondo per path, mediate sugli ultimi 5 minuti
sum by (path) (rate(hello_http_requests_total[5m]))

# Percentuale di risposte 5xx
100 * sum(rate(hello_http_requests_total{status=~"5.."}[5m]))
    / sum(rate(hello_http_requests_total[5m]))

# Quante repliche del backend sono pronte, secondo il backend stesso
sum(hello_ready)

# Repliche desiderate vs disponibili (da kube-state-metrics)
kube_deployment_spec_replicas{namespace="hello"}
kube_deployment_status_replicas_available{namespace="hello"}

# Memoria dei container del backend
sum by (pod) (container_memory_working_set_bytes{namespace="hello", container="backend"})
```

Due regole di PromQL da fissare. `rate()` si applica **solo ai counter** e gestisce da sola gli
azzeramenti dovuti ai riavvii: non si fa mai la differenza a mano tra due valori di un counter.
E `rate()` si calcola **prima** di aggregare con `sum`: `sum(rate(...))` è corretto,
`rate(sum(...))` no.

## 13.6 Grafana

```bash
pc$ kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000   utente admin, password dai valori (e poi dal SealedSecret, cap. 11)
```

Le dashboard incluse (Kubernetes / Compute Resources / Namespace (Pods), Node Exporter / Nodes)
mostrano subito CPU, memoria e rete del NUC e dei namespace. Costruisci poi una dashboard tua con
le query della sezione precedente: richieste al secondo, tasso di errore, repliche pronte.
Sono i segnali **RED** (Rate, Errors, Duration) che si usano per qualunque servizio.

## 13.7 Allarmi

Un allarme utile è **azionabile**: quando scatta, qualcuno deve fare qualcosa. Ecco una regola
per il nostro servizio, come `PrometheusRule` (esercizio 2: aggiungila al componente monitoring):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: hello-backend
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: hello-backend
      rules:
        - alert: HelloBackendHighErrorRate
          expr: |
            sum(rate(hello_http_requests_total{status=~"5.."}[5m]))
              / sum(rate(hello_http_requests_total[5m])) > 0.05
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Più del 5% di errori 5xx sul backend hello da 10 minuti"
```

`for: 10m` evita allarmi per picchi di pochi secondi. Alertmanager riceve gli allarmi e li
instrada (email, Slack, Telegram, PagerDuty), raggruppandoli e silenziandoli.

## 13.8 Esercizi

1. Esponi Grafana su `https://grafana.lab.home.arpa` con una HTTPRoute (prendi a modello quella
   di Argo CD) e aggiungi una NetworkPolicy se il namespace `monitoring` ne ha.
2. Aggiungi la `PrometheusRule` al componente Kustomize e provocala: fai rispondere il backend
   con errori (ad esempio chiamando `/api/ask` con Ollama spento, che restituisce 502).
3. Aggiungi al backend un istogramma `hello_http_request_duration_seconds` e calcola il 95°
   percentile con `histogram_quantile(0.95, sum by (le) (rate(..._bucket[5m])))`.
4. Installa Loki con Promtail/Alloy via Argo CD e cerca in Grafana i log `SIGTERM ricevuto` del
   backend durante un rollout.

<!-- nav -->
---

[← Capitolo 12 — Strumenti AI nel cluster e attorno al cluster](12-strumenti-ai.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 14 — Operazioni day‑2 →](14-operazioni-day2.md)
