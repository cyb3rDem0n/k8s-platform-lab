#!/usr/bin/env bash
# Verifica end-to-end dall'esterno del cluster, attraverso Gateway + TLS.
# Uso: scripts/smoke-test.sh [host] [ca-file]
set -euo pipefail
host="${1:-hello.lab.home.arpa}"
ca="${2:-lab-root-ca.crt}"
curl_opts=(--silent --show-error --fail-with-body --max-time 10)
if [ -f "$ca" ]; then curl_opts+=(--cacert "$ca"); else echo "(CA non trovata: uso -k)"; curl_opts+=(-k); fi

pass=0; fail=0
check() {
  local desc="$1"; shift
  if out=$("$@" 2>&1); then echo "OK   $desc"; pass=$((pass+1)); else echo "FAIL $desc"; echo "     $out"; fail=$((fail+1)); fi
}
check "redirect HTTP->HTTPS"  bash -c "curl -s -o /dev/null -w '%{http_code}' http://$host/ | grep -q 301"
check "frontend via HTTPS"    curl "${curl_opts[@]}" "https://$host/"
check "backend /api/hello"    curl "${curl_opts[@]}" "https://$host/api/hello"
check "backend /api/info"     curl "${curl_opts[@]}" "https://$host/api/info"
check "load balancing (>=2 pod diversi su 10 richieste)" bash -c \
  "for i in \$(seq 10); do curl ${curl_opts[*]} https://$host/api/hello; echo; done | grep -o '\"pod\":\"[^\"]*\"' | sort -u | wc -l | awk '\$1>=2{ok=1} END{exit !ok}'"
echo; echo "Superati: $pass  Falliti: $fail"; [ "$fail" -eq 0 ]
