# Scorciatoie per i comandi ricorrenti. `make help` per l'elenco.
SHELL := /usr/bin/env bash
KUBECONFIG ?= $(HOME)/.kube/config-nuc
export KUBECONFIG

.PHONY: help
help: ## Mostra questo aiuto
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-20s\033[0m %s\n",$$1,$$2}'

## --- Cluster -----------------------------------------------------------------------------
.PHONY: cluster
cluster: ## Provisioning del NUC con Ansible (capitolo 3)
	cd ansible && ansible-playbook site.yml

## --- Piattaforma (Terraform) --------------------------------------------------------------
.PHONY: platform platform-config
platform: ## Stadio 01: controller e CRD
	cd terraform/01-platform && terraform init -upgrade && terraform apply

platform-config: ## Stadio 02: pool IP, PKI, Gateway, route Argo CD (e root app se enable_gitops)
	cd terraform/02-platform-config && terraform init -upgrade && terraform apply

## --- Applicazione ---------------------------------------------------------------------------
.PHONY: build-local render validate helm-lint helm-render
build-local: ## Build locale delle immagini (tag dev)
	docker build -t k8s-platform-lab-backend:dev app/backend
	docker build -t k8s-platform-lab-frontend:dev app/frontend

render: ## Mostra i manifest finali dell'overlay lab
	kubectl kustomize k8s/apps/hello/overlays/lab

helm-lint: ## Lint del chart Helm
	helm lint --strict charts/hello
	helm lint --strict charts/hello -f charts/hello/values-lab.yaml

helm-render: ## Mostra i manifest generati dal chart (valori lab)
	helm template hello charts/hello -n hello-helm -f charts/hello/values-lab.yaml

validate: ## Validazione locale (come la CI)
	kubectl kustomize k8s/apps/hello/overlays/lab | kubeconform -strict -summary -ignore-missing-schemas
	helm template hello charts/hello -n hello-helm | kubeconform -strict -summary -ignore-missing-schemas
	terraform fmt -check -recursive terraform/
	cd ansible && ansible-lint --offline

## --- Operatività --------------------------------------------------------------------------
.PHONY: argocd-password smoke versions
argocd-password: ## Password iniziale di admin di Argo CD
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

smoke: ## Test end-to-end via Gateway
	scripts/smoke-test.sh

versions: ## Confronta versioni bloccate e ultime disponibili
	scripts/check-versions.sh
