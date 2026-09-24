# Kubernetes da zero a piattaforma — il tutorial

**k8s-platform-lab**: un cluster su un NUC, un backend Java, NGINX, Terraform, Argo CD, gestione
dei segreti e strumenti AI. Teoria e pratica, un livello alla volta.

Il corso è diviso in un file per capitolo, in `docs/tutorial/`. Ogni capitolo presuppone i
precedenti; ognuno termina con esercizi e con i link al capitolo precedente e successivo.

## Percorso

**Fondamenta**

- [Capitolo 0 — Come usare questo tutorial](docs/tutorial/00-come-usare-il-tutorial.md)
- [Capitolo 1 — Come funziona Kubernetes](docs/tutorial/01-come-funziona-kubernetes.md)
- [Capitolo 2 — Installare il cluster a mano con kubeadm](docs/tutorial/02-cluster-con-kubeadm.md)
- [Capitolo 3 — Automatizzare il nodo con Ansible](docs/tutorial/03-automazione-con-ansible.md)

**Applicazione**

- [Capitolo 4 — Un backend Java pensato per Kubernetes](docs/tutorial/04-backend-java.md)
- [Capitolo 5 — Il primo deploy](docs/tutorial/05-primo-deploy.md)
- [Capitolo 5B — Helm: il package manager di Kubernetes](docs/tutorial/05b-helm.md)

**Esposizione**

- [Capitolo 6 — Raggiungere l'applicazione dall'esterno](docs/tutorial/06-esposizione-esterna.md)

**Hardening**

- [Capitolo 7 — Sicurezza: rete e runtime](docs/tutorial/07-sicurezza.md)
- [Capitolo 8 — Scalabilità e resilienza](docs/tutorial/08-scalabilita-resilienza.md)

**Automazione**

- [Capitolo 9 — Terraform: la piattaforma come codice](docs/tutorial/09-terraform.md)
- [Capitolo 10 — GitOps con Argo CD](docs/tutorial/10-gitops-argocd.md)

**Strumenti**

- [Capitolo 11 — Gestione dei segreti](docs/tutorial/11-gestione-segreti.md)
- [Capitolo 12 — Strumenti AI nel cluster e attorno al cluster](docs/tutorial/12-strumenti-ai.md)
- [Capitolo 13 — Osservabilità](docs/tutorial/13-osservabilita.md)

**Operazioni**

- [Capitolo 14 — Operazioni day‑2](docs/tutorial/14-operazioni-day2.md)

**Oltre**

- [Capitolo 15 — Verso il cloud: AWS, Google Cloud, Azure](docs/tutorial/15-verso-il-cloud.md)
- [Appendici](docs/tutorial/16-appendici.md)

## Tempo stimato

Circa 30–40 ore per l'intero percorso facendo tutti gli esercizi: 6–8 per i capitoli 0–3, 8–10
per i capitoli 4–8, 8–10 per i capitoli 9–11, 6–8 per i capitoli 12–15.

## Prerequisiti di lettura

Linux da riga di comando, basi di reti (IP, subnet, DNS, HTTP/TLS), Git, un linguaggio di
programmazione. Non serve conoscere già Kubernetes: il capitolo 1 parte da zero, ma a ritmo
sostenuto.
