#!/usr/bin/env bash
# Sostituisce il segnaposto YOUR_GH_USER con il tuo utente/organizzazione GitHub in tutto il repo.
# Uso: scripts/set-repo-url.sh mio-utente
set -euo pipefail
user="${1:?Uso: $0 <utente-github>}"
cd "$(dirname "$0")/.."
files=$(grep -rl --exclude-dir=.git --exclude=set-repo-url.sh --exclude='*.md' 'YOUR_GH_USER' . || true)
[ -z "$files" ] && { echo "Nessun segnaposto trovato: già fatto?"; exit 0; }
# shellcheck disable=SC2086
sed -i.bak "s/YOUR_GH_USER/${user}/g" $files && find . -name '*.bak' -delete
echo "Aggiornati:"; printf '  %s\n' $files
