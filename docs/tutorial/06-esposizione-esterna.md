# Capitolo 6 — Raggiungere l'applicazione dall'esterno

Questo è il capitolo più denso del tutorial, perché "esporre un servizio" in Kubernetes è una
catena di quattro problemi distinti, risolti da quattro meccanismi diversi. Li affrontiamo uno
alla volta, sentendo ciascuno sulla nostra pelle prima di passare al successivo.

```
 Problema                                  Meccanismo                  Dove
 ──────────────────────────────────────────────────────────────────────────────────────
 1. Nome stabile per Pod che cambiano      Service ClusterIP           kube-proxy
 2. Entrare nel cluster dall'esterno       NodePort                    kube-proxy
 3. Un IP dedicato e raggiungibile         LoadBalancer                MetalLB (bare metal)
 4. Host, path, TLS, un solo punto d'ingresso   Gateway API (L7)       NGINX Gateway Fabric
```

## 6.1 NodePort

Un Service `NodePort` apre la stessa porta (tra 30000 e 32767) su **ogni** nodo del cluster e
inoltra il traffico ai Pod.

```bash
pc$ kubectl apply -f k8s/learn/02-frontend-nodeport.yaml
pc$ curl -s http://192.168.1.50:30080/api/hello
```

Funziona. Come: kube-proxy ha scritto nel kernel una regola del tipo "pacchetti diretti alla
porta 30080 di questo nodo: riscrivi la destinazione (DNAT) verso uno degli IP del frontend".
Con `externalTrafficPolicy: Cluster` (il default) il pacchetto può essere inoltrato a un Pod su
un altro nodo, e per garantire il ritorno kube-proxy fa anche SNAT: il Pod vede come sorgente
l'IP del nodo, non quello del client. Con `Local` il traffico va solo ai Pod sul nodo che l'ha
ricevuto e l'IP del client è preservato, al prezzo di dover mandare il traffico solo ai nodi che
hanno Pod.

I limiti di NodePort sono evidenti: porte alte e scomode, gli utenti devono conoscere l'IP di un
nodo (e se quel nodo muore?), nessun TLS, nessun instradamento per nome. Va bene per test e per
dietro un load balancer esterno. Rimuovilo:

```bash
pc$ kubectl delete -f k8s/learn/02-frontend-nodeport.yaml
```

## 6.2 LoadBalancer e il problema del bare metal

Un Service `LoadBalancer` chiede "un IP esterno dedicato". Nel cloud, un controller del provider
crea un load balancer vero (AWS NLB, Google Cloud LB, Azure LB) e scrive l'IP nello stato del
Service. Sul bare metal nessuno lo fa:

```bash
pc$ kubectl apply -f k8s/learn/03-frontend-loadbalancer.yaml
pc$ kubectl -n hello get svc hello-frontend-lb
NAME                TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)
hello-frontend-lb   LoadBalancer   10.104.x.x     <pending>     80:31xxx/TCP
```

`<pending>` per sempre. Nota anche che un Service LoadBalancer è un NodePort con qualcosa in più:
la porta 31xxx esiste già.

## 6.3 MetalLB: la teoria

**MetalLB** è il controller che fa sul bare metal quello che il cloud fa da solo. Ha due parti:
il **controller**, che assegna ai Service un IP preso da un pool configurato, e lo **speaker**,
un DaemonSet che rende quell'IP raggiungibile sulla rete.

In **modalità L2**, per ogni IP assegnato uno speaker viene eletto responsabile e risponde alle
richieste **ARP** ("chi ha 192.168.1.240?") con il MAC address del proprio nodo. Il router e i PC
della LAN mandano quindi i pacchetti per quell'IP al nodo, dove kube-proxy li instrada ai Pod.
Se il nodo cade, un altro speaker prende il suo posto e annuncia l'IP con un ARP gratuito; il
failover richiede qualche secondo.

Due conseguenze da conoscere: in L2 tutto il traffico di un IP passa da **un solo nodo**
(MetalLB fa failover, non bilanciamento tra nodi); e lo speaker deve usare la rete dell'host,
per cui il suo namespace richiede il profilo Pod Security `privileged`. L'alternativa è la
**modalità BGP**: MetalLB annuncia le rotte a un router che parla BGP, ottenendo vero
bilanciamento su più nodi. Richiede un router che lo supporti: in un datacenter è la norma, a
casa raramente.

## 6.4 MetalLB: la pratica

Installiamo a mano con Helm (capitolo 5B), usando gli stessi file di valori e manifest che Terraform userà nel
capitolo 9. Così niente è duplicato.

```bash
pc$ kubectl create namespace metallb-system
pc$ kubectl label namespace metallb-system \
      pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=privileged
pc$ helm repo add metallb https://metallb.github.io/metallb && helm repo update
pc$ helm install metallb metallb/metallb -n metallb-system --version 0.15.2 --wait
```

I manifest in `terraform/02-platform-config/manifests/` sono template Terraform con segnaposto
`${...}`. Per applicarli a mano li rendiamo con `sed`:

```bash
pc$ render() { sed -e 's/\${base_domain}/lab.home.arpa/g' \
                   -e 's/\${metallb_address_range}/192.168.1.240-192.168.1.249/g' \
                   "terraform/02-platform-config/manifests/$1.yaml"; }
pc$ render metallb-ipaddresspool   | kubectl apply -f -
pc$ render metallb-l2advertisement | kubectl apply -f -
pc$ kubectl -n hello get svc hello-frontend-lb     # EXTERNAL-IP: 192.168.1.240
pc$ curl -s http://192.168.1.240/api/hello
pc$ arp -n 192.168.1.240                           # il MAC è quello del NUC
```

Il ciclo del capitolo 1 in azione: MetalLB ha visto un Service LoadBalancer senza IP (stato
reale) diverso da ciò che serve (stato desiderato) e ha agito.

Adesso hai un IP dedicato sulla porta 80. Ma immagina dieci applicazioni: dieci IP, dieci
certificati TLS da gestire in dieci posti diversi, nessun modo di mandare `/api` a un servizio e
`/` a un altro sotto lo stesso nome. Serve un livello più alto.

```bash
pc$ kubectl delete -f k8s/learn/03-frontend-loadbalancer.yaml
```

## 6.5 Dal livello 4 al livello 7

Tutto quello visto finora lavora a **livello 4** (TCP/UDP): smista connessioni in base a IP e
porta, senza guardarne il contenuto. Un proxy di **livello 7** termina la connessione, legge la
richiesta HTTP (host, path, header) e decide dove inoltrarla. Da qui derivano tutte le funzioni
che servono in pratica: un IP per molti servizi, instradamento per nome e percorso, TLS
terminato in un punto solo, redirect, riscrittura di header, suddivisione del traffico tra
versioni.

In Kubernetes, per dieci anni, questo è stato il compito della risorsa **Ingress** e di un
**Ingress controller**, il più diffuso dei quali era **ingress-nginx**.

## 6.6 La fine di ingress-nginx e perché usiamo il Gateway API

Nel novembre 2025 il progetto Kubernetes ha annunciato il ritiro di ingress-nginx, e a marzo 2026
il ritiro è diventato effettivo: repository archiviato, nessuna release, nessuna correzione di
sicurezza. Le cause sono una manutenzione sostenuta per anni da pochissimi volontari e un debito
tecnico diventato un rischio di sicurezza: le annotazioni che permettevano di iniettare
configurazione NGINX arbitraria (gli *snippet*) erano all'origine di vulnerabilità gravi come
IngressNightmare (CVE-2025-1974). Le installazioni esistenti continuano a funzionare, ma usarlo
in un'installazione nuova oggi significa esporre su Internet un componente che non riceverà più
patch. Il comitato direttivo di Kubernetes lo ha scritto senza giri di parole.

Attenzione a non confondere tre cose con nomi simili:

- **ingress-nginx** — il controller della comunità Kubernetes, ritirato;
- **NGINX Ingress Controller** di F5/NGINX — un controller diverso, mantenuto dall'azienda, che
  implementa ancora l'API Ingress;
- **NGINX Gateway Fabric** — sempre di F5/NGINX, implementa il **Gateway API**.

L'API **Ingress** in sé non è stata rimossa, ma è congelata: nessuna nuova funzione. Il suo
successore è il **Gateway API**, stabile dal 2023. Per questo tutorial la scelta è **NGINX
Gateway Fabric**: hai chiesto NGINX, e NGINX resta il motore che smista il traffico; cambia il
modo, moderno e standard, con cui lo configuri. Tutto quello che impari sul Gateway API vale
identico con Envoy Gateway, Istio, Cilium, Traefik o i gateway gestiti dei cloud.

## 6.7 Il modello del Gateway API

Il Gateway API divide la configurazione in risorse separate, ognuna posseduta da un ruolo
diverso. È la differenza principale rispetto a Ingress, dove un unico oggetto mescolava tutto e
le funzioni avanzate finivano in annotazioni specifiche del controller.

```
 GatewayClass   "che tipo di gateway"         → fornitore dell'infrastruttura (NGF crea "nginx")
     ▲
 Gateway        "dove e come si entra"        → team piattaforma: listener, porte, hostname, TLS
     ▲  si aggancia (parentRefs)
 HTTPRoute      "dove va ogni richiesta"      → team applicativo: host, path, header → Service
```

Il team piattaforma possiede il Gateway e decide quali namespace possono agganciarsi
(`allowedRoutes`). Ogni team applicativo possiede le proprie HTTPRoute nel proprio namespace,
senza poter toccare il TLS o le porte del Gateway. Se una route deve puntare a un Service in un
altro namespace, serve una **ReferenceGrant** nel namespace di destinazione: il consenso è
esplicito da entrambe le parti.

Ogni risorsa riporta nello `status` delle **condizioni** leggibili: `Accepted` (la risorsa è
valida e il controller l'ha presa in carico), `Programmed` (la configurazione è attiva nel data
plane), `ResolvedRefs` (i riferimenti a Service e Secret sono risolti). Il debugging del Gateway
API inizia quasi sempre da `kubectl describe`.

## 6.8 Installare le CRD e NGINX Gateway Fabric

Il Gateway API non è incluso in Kubernetes: è un insieme di CRD da installare. La versione deve
essere quella supportata dall'implementazione (NGF 2.6 supporta Gateway API 1.4).

```bash
pc$ kubectl apply --server-side \
      -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
pc$ kubectl get crd | grep gateway.networking.k8s.io
```

`--server-side` sposta il calcolo delle modifiche sull'API server: le CRD sono così grandi da
superare il limite dell'annotazione usata dall'apply tradizionale.

```bash
pc$ helm install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --version 2.6.0 \
      -n nginx-gateway --create-namespace \
      -f terraform/01-platform/values/nginx-gateway-fabric.yaml --wait
pc$ kubectl get gatewayclass
NAME    CONTROLLER                                   ACCEPTED
nginx   gateway.nginx.org/nginx-gateway-controller   True
```

L'architettura di NGF separa **control plane** e **data plane**. Il control plane (il Deployment
`ngf-nginx-gateway-fabric`) osserva Gateway, route, Service ed EndpointSlice e genera la
configurazione di NGINX. Per ogni Gateway crea un Deployment di NGINX dedicato e un Service di
tipo LoadBalancer; la configurazione viene inviata ai Pod NGINX tramite un agente. Il control
plane non tocca mai il traffico: se si ferma, NGINX continua a servire con l'ultima
configurazione valida.

## 6.9 Il primo Gateway, solo HTTP

Prima di aggiungere il TLS, verifichiamo il percorso in chiaro con un Gateway minimo e una route
temporanea:

```bash
pc$ kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-gateway
  namespace: nginx-gateway
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      hostname: "*.lab.home.arpa"
      allowedRoutes:
        namespaces: { from: All }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: hello-temp
  namespace: hello
spec:
  parentRefs: [{ name: lab-gateway, namespace: nginx-gateway }]
  hostnames: ["hello.lab.home.arpa"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /api } }]
      backendRefs: [{ name: hello-backend, port: 8080 }]
    - backendRefs: [{ name: hello-frontend, port: 80 }]
EOF
pc$ kubectl -n nginx-gateway get gateway lab-gateway     # ADDRESS assegnato da MetalLB, PROGRAMMED True
pc$ kubectl -n nginx-gateway get deploy,svc              # il data plane NGINX creato per questo Gateway
pc$ GW=$(kubectl -n nginx-gateway get gateway lab-gateway -o jsonpath='{.status.addresses[0].value}')
pc$ curl -s -H 'Host: hello.lab.home.arpa' http://$GW/api/hello
```

Nota come ora `/api` va **direttamente** al backend: il Gateway sceglie in base al path, e la
richiesta non passa più dal frontend nginx. Prova anche un host diverso:
`curl -H 'Host: altro.lab.home.arpa' http://$GW/` restituisce 404, perché nessuna route lo
dichiara.

## 6.10 TLS con cert-manager e una CA interna

**cert-manager** è un controller che emette e **rinnova** certificati. I suoi concetti:

- **Issuer / ClusterIssuer** — chi firma i certificati (una CA interna, Let's Encrypt via ACME,
  Vault...). Il primo vale in un namespace, il secondo in tutto il cluster.
- **Certificate** — "voglio un certificato per questi nomi, salvato in questo Secret".
  cert-manager genera la chiave, la fa firmare, scrive il Secret, e lo rinnova prima della
  scadenza.

*Perché non Let's Encrypt:* il dominio `home.arpa` è riservato alle reti domestiche (RFC 8375) e
non è pubblico, quindi nessuna CA pubblica emetterà certificati per esso. Con un dominio tuo,
Let's Encrypt funzionerebbe con la sfida **DNS-01** (cert-manager crea un record TXT tramite le
API del tuo provider DNS), che non richiede di esporre il cluster su Internet. Per il laboratorio
costruiamo una **PKI interna** in tre passi, lo stesso schema usato nelle aziende per i servizi
interni:

```
 ClusterIssuer "selfsigned-bootstrap"   firma una sola cosa:
        │
        ▼
 Certificate "lab-root-ca" (isCA: true, 10 anni)  → Secret lab-root-ca in cert-manager
        │
        ▼
 ClusterIssuer "lab-ca"                 firma tutti i certificati del laboratorio
```

Installa cert-manager con il supporto al Gateway API attivo (vedi il file di valori):

```bash
pc$ helm repo add jetstack https://charts.jetstack.io && helm repo update
pc$ helm install cert-manager jetstack/cert-manager --version v1.18.2 \
      -n cert-manager --create-namespace -f terraform/01-platform/values/cert-manager.yaml --wait
pc$ render issuer-selfsigned       | kubectl apply -f -
pc$ render certificate-lab-root-ca | kubectl apply -f -
pc$ render issuer-lab-ca           | kubectl apply -f -
pc$ kubectl get clusterissuer                           # entrambi READY True
```

Ora sostituisci il Gateway minimo con quello definitivo, che ha anche il listener HTTPS e
un'annotazione per cert-manager:

```bash
pc$ render gateway | kubectl apply -f -
pc$ kubectl -n nginx-gateway get certificate            # lab-wildcard-tls, READY True
```

Con `enableGatewayAPI`, cert-manager osserva i Gateway annotati con
`cert-manager.io/cluster-issuer`. Per ogni listener HTTPS con `hostname` e `certificateRefs`
crea da solo un Certificate: qui uno solo, wildcard `*.lab.home.arpa`, salvato nel Secret
`lab-wildcard-tls` che il listener usa. Rinnovo automatico incluso.

Infine applica le route definitive dell'app e cancella quella temporanea:

```bash
pc$ kubectl delete httproute -n hello hello-temp
pc$ kubectl apply -k k8s/apps/hello/base/routing
pc$ kubectl -n hello describe httproute hello           # Accepted, ResolvedRefs: True
```

`base/routing` contiene due route. `hello` è agganciata al listener `https` (`sectionName:
https`) e divide `/api` e `/`. `hello-http-redirect` è agganciata al listener `http` e risponde
a qualunque richiesta con un redirect 301 verso HTTPS, tramite il filtro `RequestRedirect`.

## 6.11 Nomi e fiducia

Il nome `hello.lab.home.arpa` deve risolvere nell'IP del Gateway. La soluzione più semplice è
`/etc/hosts` su ogni macchina che lo usa:

```bash
pc$ echo "$GW hello.lab.home.arpa argocd.lab.home.arpa" | sudo tee -a /etc/hosts
```

Quella migliore è un record DNS wildcard `*.lab.home.arpa` sul DNS locale (router, Pi-hole,
AdGuard Home): ogni nuova applicazione è subito raggiungibile da tutta la casa.

Il browser, poi, non si fida della nostra CA. Esporta il certificato radice e importalo nel
sistema operativo:

```bash
pc$ kubectl -n cert-manager get secret lab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > lab-root-ca.crt
# macOS
pc$ sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain lab-root-ca.crt
# Ubuntu/Debian
pc$ sudo cp lab-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
# Windows (PowerShell da amministratore)
PS> certutil -addstore -f Root lab-root-ca.crt
```

Consapevolezza di sicurezza: chi possiede la chiave privata di questa CA può emettere
certificati validi per **qualunque** sito agli occhi delle macchine che le danno fiducia. Va
bene per un laboratorio personale; in azienda la fiducia in una CA interna si limita ai domini
interni (vincoli di nome) e la chiave vive in un HSM o in Vault.

**Verifica:**

```bash
pc$ curl -sI http://hello.lab.home.arpa/                       # 301 → https
pc$ curl -s --cacert lab-root-ca.crt https://hello.lab.home.arpa/api/hello
pc$ scripts/smoke-test.sh
```

## 6.12 Il viaggio di una richiesta

Mettiamo insieme tutto. Digiti `https://hello.lab.home.arpa/api/hello` nel browser:

1. **DNS** — `/etc/hosts` risolve il nome in 192.168.1.240.
2. **ARP** — il PC chiede sulla LAN chi ha 192.168.1.240; lo speaker di MetalLB risponde con il
   MAC del NUC.
3. **Nodo** — il pacchetto arriva alla scheda di rete del NUC. Le regole nftables di kube-proxy
   per il Service LoadBalancer del data plane lo inoltrano a un Pod NGINX. Con
   `externalTrafficPolicy: Local` l'IP del client è preservato: lo vedrai nei log di NGINX.
4. **NGINX (Gateway)** — completa l'handshake TLS con il certificato wildcard firmato da `lab-ca`,
   legge host e path, trova la regola `/api` della route `hello`, sceglie un Pod del backend. NGF
   configura NGINX con gli IP dei Pod presi dagli EndpointSlice, quindi il traffico va dritto al
   Pod senza passare di nuovo dall'IP virtuale del Service.
5. **Rete dei Pod** — Calico instrada il pacchetto al Pod del backend (sullo stesso nodo,
   attraverso un'interfaccia virtuale).
6. **Backend** — un virtual thread gestisce la richiesta; la risposta ripercorre la catena.

Quando qualcosa non funziona, percorri questa lista e verifica ogni anello: `getent hosts`,
`arp -n`, `kubectl get svc -n nginx-gateway`, `describe gateway` e `describe httproute`, log del
data plane NGINX, EndpointSlice del backend, log del backend.

## 6.13 Due NGINX, due ruoli

In questa architettura NGINX compare due volte, con ruoli diversi. Il **Gateway** è il proxy di
frontiera condiviso: TLS, instradamento tra applicazioni, redirect. Il container **frontend** è
un web server applicativo: serve file statici e, per comodità, inoltra `/api` al backend. Con il
Gateway in funzione quella seconda funzione non viene usata, perché il Gateway manda `/api`
direttamente al backend; resta utile in Compose, con il port-forward, e come dimostrazione che
la stessa immagine funziona in ambienti diversi. In un progetto reale potresti eliminarla: è una
scelta di progetto, e ora sai valutarla.

## 6.14 Troubleshooting del Gateway API

- **Gateway senza ADDRESS** — MetalLB non ha assegnato l'IP: `kubectl -n nginx-gateway get svc`,
  poi `kubectl -n metallb-system logs deploy/metallb-controller`. Pool esaurito o assente?
- **Route con `Accepted: False`** — leggi il `reason`: `NotAllowedByListeners` (il namespace non
  è ammesso o il `sectionName` è sbagliato), `NoMatchingListenerHostname` (l'host della route non
  rientra nel wildcard del listener).
- **`ResolvedRefs: False`** — il Service o la porta nella `backendRefs` non esiste, oppure punta
  a un altro namespace senza ReferenceGrant.
- **Listener HTTPS non programmato** — il Secret del certificato non esiste ancora:
  `kubectl -n nginx-gateway describe certificate`, poi `kubectl -n cert-manager logs deploy/cert-manager`.
- **502/504** — NGINX non raggiunge i Pod: EndpointSlice vuoti? NetworkPolicy che blocca (dal
  capitolo 7)? Log del data plane: `kubectl -n nginx-gateway logs deploy/<nome-del-data-plane>`.

## 6.15 Esercizi

1. **Canary release.** Crea un Deployment `hello-backend-v2` con un `GREETING` diverso e un
   Service dedicato. Modifica la regola `/api` in modo che abbia due `backendRefs` con `weight: 90`
   e `weight: 10`. Chiama l'API cento volte e conta le risposte.
2. **Routing per header.** Aggiungi una regola che manda al v2 solo le richieste con header
   `X-Canary: true`, utile per far provare una versione a un gruppo ristretto.
3. **Grafana** (dopo il capitolo 13): scrivi l'HTTPRoute per `grafana.lab.home.arpa`. Non serve
   toccare il Gateway né i certificati: il wildcard copre già il nuovo nome. È la separazione dei
   ruoli in pratica.

<!-- nav -->
---

[← Capitolo 5B — Helm: il package manager di Kubernetes](05b-helm.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 7 — Sicurezza: rete e runtime →](07-sicurezza.md)
