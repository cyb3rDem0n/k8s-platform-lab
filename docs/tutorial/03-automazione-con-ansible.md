# Capitolo 3 — Automatizzare il nodo con Ansible

## 3.1 Perché automatizzare quello che hai appena fatto

Hai eseguito una ventina di comandi. Tra sei mesi, per reinstallare il NUC o aggiungere un
secondo nodo, dovresti ricordarli tutti, nello stesso ordine, con le stesse opzioni, e qualcuno
nel frattempo sarà cambiato. L'automazione non serve a risparmiare tempo la prima volta: serve a
rendere l'operazione **ripetibile, revisionabile e documentata dal codice stesso**.

## 3.2 I concetti di Ansible

Ansible è **agentless**: dalla tua macchina si collega via SSH ai nodi ed esegue moduli Python.
Non serve installare nulla sul NUC oltre a Python, già presente su Ubuntu.

- **Inventario** — l'elenco degli host e dei gruppi (`inventory/hosts.ini`) e delle loro
  variabili (`inventory/group_vars/`).
- **Playbook** — una sequenza di *play*; ogni play applica ruoli o task a un gruppo di host.
- **Ruolo** — un pacchetto riutilizzabile di task, handler, default e template.
- **Modulo** — l'unità che fa il lavoro: `apt`, `copy`, `template`, `systemd_service`...
- **Handler** — un task eseguito solo se notificato da un altro task che ha prodotto un
  cambiamento (es. riavviare containerd solo se la sua configurazione è cambiata).

Il concetto più importante è **l'idempotenza**: eseguire il playbook una volta o dieci volte
produce lo stesso risultato. I moduli dichiarano uno stato ("il pacchetto X deve essere
presente") invece di un'azione ("installa X"). Ansible riporta per ogni task `ok` (già a posto),
`changed` (modificato) o `failed`. Una seconda esecuzione deve riportare zero `changed`: è la
prova che l'automazione è corretta.

## 3.3 La struttura del nostro playbook

```
ansible/
├── ansible.cfg                  inventario di default, sudo, output leggibile
├── inventory/
│   ├── hosts.ini                gruppi control_plane, workers, k8s
│   └── group_vars/k8s.yml       k8s_minor, CIDR, versione di Calico
├── site.yml                     play 1: common+containerd+kube_tools su tutti; play 2: cluster_init
├── reset.yml                    distrugge il cluster (con conferma esplicita)
└── roles/
    ├── common/                  pacchetti, swap, moduli, sysctl
    ├── containerd/              repository Docker, containerd.io, config, SystemdCgroup
    ├── kube_tools/              repository pkgs.k8s.io, pacchetti, hold
    └── cluster_init/            kubeadm init da template, Calico, untaint, fetch del kubeconfig
```

Ogni ruolo corrisponde a una sezione del capitolo 2. Alcuni dettagli di progetto:

**`deb822_repository` invece di `apt_key` + `apt_repository`.** `apt_key` è deprecato da anni;
il formato deb822 è il formato moderno delle sorgenti apt, e il modulo scarica e collega la
chiave di firma in un solo passaggio.

**Generazione una tantum della configurazione di containerd.** Il task usa
`creates: /etc/containerd/.generated-by-ansible`: rigenera il file solo la prima volta. Senza
questa guardia, ogni esecuzione sovrascriverebbe il file, il task risulterebbe sempre `changed`
e containerd verrebbe riavviato ogni volta.

**`kubeadm init` protetto da `creates: /etc/kubernetes/admin.conf`.** Se il file esiste, il
cluster esiste già e il comando non viene rieseguito. È il modo più semplice per rendere
idempotente un comando che per natura non lo è.

**La versione di Kubernetes letta da kubeadm.** Il template non contiene una patch fissa: il
ruolo esegue `kubeadm version -o short` e la usa. Il repository apt decide la minor,
l'installazione decide la patch: nessuna possibilità di disallineamento.

**Il kubeconfig scaricato con `fetch`** in `~/.kube/config-nuc` sulla tua macchina: alla fine
del playbook puoi usare subito `kubectl`.

**Nomi delle variabili con il prefisso del ruolo** (`cluster_init_…`, `kube_tools_…`): è una
regola di `ansible-lint` che evita collisioni tra ruoli. Il repository passa il profilo più
severo, `production`.

## 3.4 Eseguire

```bash
pc$ python3 -m pip install --user ansible-core
pc$ cd ansible
pc$ ansible-galaxy collection install -r requirements.yml
pc$ ssh giuseppe@192.168.1.50 true          # accetta la chiave host una volta
pc$ ansible nuc -m ping                      # "pong"
pc$ ansible-playbook site.yml --check --diff # anteprima (alcuni task dipendenti non sono simulabili)
pc$ ansible-playbook site.yml
```

## 3.5 Dimostrare la ricostruibilità

Questo è l'esercizio che distingue chi "ha fatto un playbook" da chi ha un'infrastruttura
riproducibile.

```bash
pc$ ansible-playbook reset.yml -e confirm=yes   # distrugge il cluster
pc$ ansible-playbook site.yml                   # lo ricrea
pc$ ansible-playbook site.yml                   # seconda esecuzione: changed pari a zero, o quasi
```

Se la seconda esecuzione riporta dei `changed`, individua il task e chiediti perché non è
idempotente. Spesso è un `command:` senza `changed_when` o `creates`. Alcuni task di questo
repository (l'apply di Calico) usano `changed_when` basato sull'output di kubectl proprio per
questo motivo.

## 3.6 Esercizi

1. Aggiungi un secondo nodo worker (una VM va benissimo) al gruppo `[workers]`. Scrivi un ruolo
   `worker_join` che ricava il comando con `kubeadm token create --print-join-command` sul
   control plane (usa `delegate_to`) e lo esegue sul worker, protetto da
   `creates: /etc/kubernetes/kubelet.conf`.
2. Aggiungi `ansible-lint` in un hook di pre-commit.
3. Sposta `calico_version` e `k8s_minor` in un file di versioni unico, letto anche da
   `scripts/check-versions.sh`.

<!-- nav -->
---

[← Capitolo 2 — Installare il cluster a mano con kubeadm](02-cluster-con-kubeadm.md)  ·  [Indice](../../TUTORIAL.md)  ·  [Capitolo 4 — Un backend Java pensato per Kubernetes →](04-backend-java.md)
