#!/bin/bash
# Start the stack on the v1 release and wait until every service answers.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo ".env is missing. Run lab/wire-credentials.sh first." >&2; exit 1; }

# HTTPS for Workflow Automation (the tls service) only when track setup installed the certificate.
profiles=()
[ -s /etc/ssl/certs/sandbox.crt ] && [ -s /etc/ssl/private/sandbox.key ] && profiles=(--profile tls)
docker compose "${profiles[@]}" up -d

wait_for() {  # wait_for NAME URL
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 "$2" >/dev/null 2>&1; then echo "$1 is up"; return 0; fi
    sleep 2
  done
  echo "$1 did not become healthy: $2" >&2
  docker compose ps >&2
  return 1
}

wait_for shop-api http://localhost:5000/health
wait_for controller http://localhost:5001/health
if [ ${#profiles[@]} -gt 0 ]; then
    curl -fsS --max-time 5 --resolve "wfa-infra.${_SANDBOX_ID:-local}.instruqt.io:5443:127.0.0.1" \
        "https://wfa-infra.${_SANDBOX_ID:-local}.instruqt.io:5443/health" >/dev/null 2>&1 \
        && echo "controller HTTPS is up on 5443" || echo "controller HTTPS on 5443 is not answering yet" >&2
fi
curl -fsS http://localhost:5000/api/status; echo
