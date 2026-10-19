#!/bin/bash
# Collect the three New Relic values, validate them, and write .env for Docker Compose.
# Values already in the environment are used as is (instructor-led or scripted runs).
set -euo pipefail

cd "$(dirname "$0")/.."
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

ask() {  # ask VAR "prompt" [secret]
  local var="$1" prompt="$2" secret="${3:-}"
  if [ -n "${!var:-}" ]; then return; fi
  if [ ! -t 0 ]; then echo "$var is not set and there is no terminal to ask on" >&2; exit 1; fi
  if [ -n "$secret" ]; then read -r -s -p "$prompt: " "$var"; echo; else read -r -p "$prompt: " "$var"; fi
  export "${var?}"
}

ask NEW_RELIC_LICENSE_KEY "Ingest license key" secret
ask NEW_RELIC_API_KEY "User API key (NRAK-...)" secret
ask NEW_RELIC_ACCOUNT_ID "Account ID (numbers only)"

[[ "$NEW_RELIC_ACCOUNT_ID" =~ ^[0-9]+$ ]] || { echo "Account ID must be numeric" >&2; exit 1; }
[[ "$NEW_RELIC_API_KEY" == NRAK-* ]] || { echo "The user API key should start with NRAK-" >&2; exit 1; }
[ "${#NEW_RELIC_LICENSE_KEY}" -ge 32 ] || { echo "The license key looks too short" >&2; exit 1; }

echo "Validating the user API key and account ID..."
name=$(curl -fsS --max-time 20 https://api.newrelic.com/graphql \
  -H "Content-Type: application/json" -H "API-Key: $NEW_RELIC_API_KEY" \
  -d "{\"query\":\"{ actor { account(id: $NEW_RELIC_ACCOUNT_ID) { name } } }\"}" \
  </dev/null | jq -r '.data.actor.account.name // empty') || true
[ -n "$name" ] || { echo "NerdGraph did not return that account. Check the user API key and account ID." >&2; exit 1; }
echo "Account: $name"

# Keep the controller secret stable across re-runs.
secret=""
if [ -f .env ]; then secret=$(grep -E '^ROLLBACK_SECRET=' .env | cut -d= -f2- || true); fi
[ -n "$secret" ] || secret=$(openssl rand -hex 20)

umask 077
cat > .env <<EOF
NEW_RELIC_LICENSE_KEY=$NEW_RELIC_LICENSE_KEY
NEW_RELIC_API_KEY=$NEW_RELIC_API_KEY
NEW_RELIC_ACCOUNT_ID=$NEW_RELIC_ACCOUNT_ID
ROLLBACK_SECRET=$secret
EOF
echo "Wrote .env (not tracked by git)."
