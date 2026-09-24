# Capitolo 8 — Scalabilità e resilienza

## 8.1 metrics-server

L'HorizontalPodAutoscaler ha bisogno di sapere quanta CPU e memoria usano i Pod. La fonte è
**metrics-server**, che interroga periodicamente i kubelet e pubblica i valori tramite l'API
`metrics.k8s.io`. Non è un sistema di monitoraggio (non conserva storia): è solo la fonte per
`kubectl top` e per l'autoscaling.

```bash
pc$ helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
pc$ helm install metrics-server metrics-server/metrics-server -n kube-system --version 3.12.2 \
      -f terraform/01-platform/values/metrics-server.yaml --wait
pc$ kubectl top nodes && kubectl -n hello top pods
```

Il file di valori contiene `--kubelet-insecure-tls`. *Perché:* in un cluster kubeadm i kubelet
usano certificati di servizio autofirmati, che metrics-server non riesce a verificare. In
laboratorio disattiviamo la verifica; in produzione si abilita `serverTLSBootstrap: true` nella
configurazione del kubelet, così i kubelet chiedono certificati firmati dalla CA del cluster
tramite CSR, che vanno poi approvati (a mano o con un approvatore automatico).

## 8.2 HorizontalPodAutoscaler

Il nostro HPA (`base/core/hpa.yaml`) mantiene tra 2 e 5 repliche del backend puntando al 70% di
utilizzo della CPU. Il punto chiave: la percentuale è calcolata **rispetto alle requests**, non
alla CPU del nodo. Con una request di 50m, il 70% corrisponde a 35 millicore per Pod.

Il calcolo, eseguito ogni 15 secondi:

```
repliche_desiderate = ceil( repliche_attuali × utilizzo_attuale / utilizzo_obiettivo )

esempio: 2 repliche al 140%  →  ceil(2 × 140 / 70) = 4 repliche
```

La sezione `behavior.scaleDown.stabilizationWindowSeconds: 120` fa sì che, per ridurre, l'HPA
usi il valore più alto raccomandato negli ultimi due minuti: evita l'oscillazione continua
(*flapping*) quando il carico è irregolare. Lo scale-up invece è immediato.

Conseguenza pratica importante: requests sbagliate producono autoscaling sbagliato. Requests
troppo basse fanno scalare al minimo carico; troppo alte non fanno scalare mai.

## 8.3 Provare sotto carico

Genera carico dalla tua macchina attraverso il Gateway, con uno strumento come `hey` o `oha`:

```bash
pc$ kubectl -n hello get hpa hello-backend -w        # in un terminale
pc$ hey -z 120s -c 50 https://hello.lab.home.arpa/api/hello      # nell'altro (con la CA di sistema installata)
```

Osserva la colonna TARGETS salire oltre il 70%, le repliche aumentare, poi, finito il carico,
tornare a 2 dopo la finestra di stabilizzazione. Guarda anche gli eventi: `kubectl -n hello
describe hpa hello-backend`.

Quando Argo CD gestirà il Deployment, dovrà ignorare `spec.replicas`, altrimenti riporterebbe a
2 ogni scalata dell'HPA. Lo vedremo nel capitolo 10 (`ignoreDifferences`).

Altri autoscaler da conoscere: il **VerticalPodAutoscaler** suggerisce o applica requests
corrette osservando i consumi reali; **KEDA** scala su metriche di evento (lunghezza di una coda,
una query Prometheus), fino a zero repliche. Per un servizio LLM, scalare sul numero di richieste
in attesa è molto più sensato che scalare sulla CPU.

## 8.4 PodDisruptionBudget

Le interruzioni sono di due tipi. **Involontarie**: un nodo si spegne, il kernel uccide un
processo. **Volontarie**: qualcuno esegue `kubectl drain` per la manutenzione, un upgrade del
cluster, l'autoscaler dei nodi che rimuove un nodo. Il **PodDisruptionBudget** protegge dalle
seconde: la API di *eviction*, usata da drain e dagli upgrade, rifiuta di sfrattare un Pod se
farlo violerebbe il budget.

Il nostro PDB richiede `minAvailable: 1` per il backend. Su più nodi, un drain sposterà i Pod uno
alla volta, aspettando che il sostituto sia pronto. Su un nodo solo, un drain resterà bloccato
per sempre, perché non c'è un altro posto dove far ripartire il Pod: è il comportamento corretto,
e il capitolo 14 mostra come gestirlo durante un upgrade.

## 8.5 Esercizi

1. Porta la request di CPU del backend a `10m` e ripeti il test di carico: cosa succede e perché?
2. Aggiungi all'HPA una seconda metrica sulla memoria. Con due metriche, l'HPA sceglie il numero
   di repliche più alto tra quelli calcolati.
3. Con un secondo nodo (esercizio del capitolo 3), esegui `kubectl drain` e osserva il PDB che
   regola lo sfratto.

<!-- nav -->
---

[← Capitolo 7 — Sicurezza: rete e runtime](07-sicurezza.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 9 — Terraform: la piattaforma come codice →](09-terraform.md)
