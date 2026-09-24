# Capitolo 0 — Come usare questo tutorial

## 0.1 Il metodo: prima a mano, poi automatizzato

Ogni strumento di automazione nasconde qualcosa. Se installi Kubernetes direttamente con un
playbook, il giorno in cui il playbook fallisce non sai dove guardare. Per questo il tutorial
segue sempre lo stesso schema: prima fai l'operazione a mano capendo ogni passo, poi la
automatizzi, poi distruggi e ricostruisci per dimostrare che l'automazione è completa.

La sequenza degli strati è questa, ed è la stessa che troverai in qualunque azienda seria:

```
  Strato                   Strumento           Domanda a cui risponde
  ─────────────────────────────────────────────────────────────────────────────
  4. Carichi applicativi   Argo CD (GitOps)    "Cosa deve girare nel cluster?"
  3. Piattaforma           Terraform           "Quali servizi di base offre il cluster?"
  2. Cluster               kubeadm             "Come nasce il control plane?"
  1. Sistema operativo     Ansible             "Com'è configurata la macchina?"
  0. Hardware              il NUC              "Dove gira tutto?"
```

Quando arriveremo al cloud cambieranno gli strati 0, 1 e 2 (li fornisce il provider), e in
parte il 3. Lo strato 4, quello che hai scritto tu, resterà quasi identico: è il motivo per cui
vale la pena imparare bene GitOps.

## 0.2 Convenzioni

I blocchi di codice indicano sempre dove vanno eseguiti. `nuc$` significa sul NUC via SSH,
`pc$` significa sulla tua macchina. Dove non è indicato, si intende la tua macchina con
`KUBECONFIG` che punta al cluster.

Ogni sezione pratica termina con una **verifica**: un comando e l'output atteso. Non passare
alla sezione successiva finché la verifica non passa. Gran parte dei problemi che si incontrano
con Kubernetes nasce da un passo precedente dato per buono.

Le sezioni che iniziano con *Perché* spiegano le scelte di progettazione. Sono quelle che fanno
la differenza in un colloquio: chiunque sa scrivere un Deployment copiandolo, poche persone sanno
dire perché `maxUnavailable: 0` o perché niente limit di CPU.

## 0.3 Hardware e rete

Il riferimento è un Intel NUC (o mini‑PC equivalente) con 4+ core, 16 GB di RAM, SSD da
100+ GB, collegato via cavo alla LAN di casa. Ubuntu Server 24.04 LTS, installazione minima,
OpenSSH attivo, accesso con chiave SSH e `sudo`.

Prima di cominciare, sul router:

1. Riserva un IP fisso al NUC (nei nostri esempi `192.168.1.50`).
2. Individua il range DHCP del router (es. `192.168.1.100–199`) e scegli un blocco di IP
   **fuori** da quel range per MetalLB (negli esempi `192.168.1.240–249`). Se MetalLB assegna
   un IP che il router dà anche via DHCP a un telefono, avrai due dispositivi con lo stesso
   indirizzo e un pomeriggio di debugging surreale.

Sul NUC, verifica i requisiti minimi di kubeadm:

```bash
nuc$ nproc                                  # >= 2 (meglio 4+)
nuc$ free -h                                # >= 2 GB (meglio 16 GB per LLM e monitoring)
nuc$ cat /sys/class/dmi/id/product_uuid     # deve essere UNICO tra i nodi (clonare VM lo duplica)
nuc$ ip link                                # anche i MAC address devono essere unici
```

## 0.4 Preparare il repository

```bash
pc$ git clone https://github.com/<tu>/k8s-platform-lab.git   # dopo il fork su GitHub
pc$ cd k8s-platform-lab
pc$ scripts/set-repo-url.sh <tu>      # sostituisce YOUR_GH_USER nei manifest
pc$ git commit -am "chore: set repo owner" && git push
```

<!-- nav -->
---

[Indice](../../TUTORIAL.md)  ·  [Capitolo 1 — Come funziona Kubernetes →](01-come-funziona-kubernetes.md)
