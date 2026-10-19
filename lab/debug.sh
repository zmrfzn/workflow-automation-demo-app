#!/bin/bash
# Show the state of the lab, and restart or reset it when something is off.
#   debug.sh                  status (default): credentials, containers, release, health, agents
#   debug.sh restart [svc]    restart one service, or the whole stack when none is given
#   debug.sh reset            back to the v1 baseline with an empty cache (through the controller)
#   debug.sh logs [svc]       last 50 log lines of one service, or of every service
set -uo pipefail

cd "$(dirname "$0")/.."
SERVICES="shop-api redis loadgen controller"

ok()   { printf '  [ok]   %s\n' "$1"; }
bad()  { printf '  [FAIL] %s\n' "$1"; }
info() { printf '  %s\n' "$1"; }

env_value() { grep -E "^$1=" .env 2>/dev/null | cut -d= -f2- || true; }

known_service() {
  for s in $SERVICES; do [ "$s" = "$1" ] && return 0; done
  echo "Unknown service '$1'. Use one of: $SERVICES" >&2
  exit 2
}

status() {
  echo "Credentials (.env)"
  if [ -f .env ]; then
    for var in NEW_RELIC_LICENSE_KEY NEW_RELIC_API_KEY NEW_RELIC_ACCOUNT_ID ROLLBACK_SECRET; do
      val=$(env_value "$var")
      if [ -n "$val" ]; then ok "$var is set (...${val: -4})"; else bad "$var is empty"; fi
    done
  else
    bad ".env is missing. Run ./lab/wire-credentials.sh"
  fi

  echo
  echo "Containers"
  docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}' 2>/dev/null \
    || bad "docker compose could not list the stack"

  echo
  echo "Services"
  release=$(curl -fsS --max-time 3 http://localhost:5000/api/status 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  if [ -n "$release" ]; then ok "shop-api answers on port 5000, release $release"; else bad "shop-api is not answering on port 5000"; fi
  if curl -fsS --max-time 3 http://localhost:5001/health >/dev/null 2>&1; then
    ok "controller answers on port 5001"
    last=$(curl -fsS --max-time 3 http://localhost:5001/status 2>/dev/null \
      | jq -r '.history[-1] | select(.) | "\(.ts[11:19]) \(.action) \(.version_before) -> \(.version_after) by \(.triggered_by)"' 2>/dev/null)
    info "last controller action: ${last:-none}"
  else
    bad "controller is not answering on port 5001"
  fi

  echo
  echo "New Relic"
  if systemctl is-active --quiet newrelic-infra 2>/dev/null; then ok "infrastructure agent is running"; else bad "infrastructure agent is not running. Run ./lab/install-agents.sh"; fi
  info "expected APM apps: wfa-shop-api, wfa-controller, wfa-loadgen"

  echo
  echo "Memory"
  docker stats --no-stream --format '  {{.Name}}\t{{.MemUsage}}' 2>/dev/null || true

  if [ -f /var/log/wfa-setup.log ]; then
    echo
    info "Track setup log: /var/log/wfa-setup.log"
  fi
  echo
  echo "Next: ./lab/debug.sh restart [service] | reset | logs [service]"
}

restart() {
  if [ -n "${1:-}" ]; then
    known_service "$1"
    docker compose restart "$1"
  else
    docker compose up -d
    docker compose restart
  fi
  status
}

reset() {
  secret=$(env_value ROLLBACK_SECRET)
  if [ -n "$secret" ] && curl -fsS --max-time 3 http://localhost:5001/health >/dev/null 2>&1; then
    curl -fsS --max-time 200 -X POST http://localhost:5001/reset \
      -H "X-Rollback-Token: $secret" -H 'Content-Type: application/json' \
      -d '{"triggered_by":"debug-script"}' | jq .
  else
    # Controller is down or unconfigured: do the same thing by hand.
    echo "Controller unavailable, resetting directly."
    APP_TAG=v1 docker compose up -d --force-recreate shop-api
    docker compose up -d
    docker compose exec -T redis redis-cli FLUSHALL
  fi
  status
}

logs() {
  if [ -n "${1:-}" ]; then known_service "$1"; docker compose logs --tail 50 "$1"
  else docker compose logs --tail 50; fi
}

case "${1:-status}" in
  status)  status ;;
  restart) restart "${2:-}" ;;
  reset)   reset ;;
  logs)    logs "${2:-}" ;;
  *) echo "Usage: $0 [status | restart [service] | reset | logs [service]]" >&2; exit 2 ;;
esac
