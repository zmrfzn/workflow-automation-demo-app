#!/bin/bash
# End-to-end check of a running stack: v1 healthy, deploy v2 breaks it, rollback fixes it.
# Needs ROLLBACK_SECRET (read from .env if present). Does not need New Relic.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] && { set -a; . ./.env; set +a; }
: "${ROLLBACK_SECRET:?ROLLBACK_SECRET is required}"

APP=${APP:-http://localhost:5000}
CTL=${CTL:-http://localhost:5001}
pass() { echo "PASS  $1"; }
die() { echo "FAIL  $1" >&2; exit 1; }
call() { curl -fsS --max-time 200 -X POST "$CTL/$1" -H "X-Rollback-Token: $ROLLBACK_SECRET" \
  -H 'Content-Type: application/json' -d "${2:-{\}}"; }
errors() {  # count 5xx over 40 requests to the always-buggy endpoint
  local n=0 code
  for _ in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$APP/api/checkout" || echo 000)
    [ "$code" -ge 500 ] || [ "$code" = 000 ] && n=$((n + 1))
  done
  echo "$n"
}

[ "$(curl -fsS "$CTL/status" | jq -r .version)" = v1 ] || { call reset >/dev/null; }
pass "baseline is v1"

[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$CTL/rollback")" = 401 ] || die "unauthenticated rollback was not refused"
pass "write endpoints refuse a missing token"

[ "$(errors)" -le 2 ] || die "v1 returned errors"
pass "v1 serves checkout cleanly"

out=$(call deploy '{"version":"v2"}')
[ "$(echo "$out" | jq -r .version_after)" = v2 ] || die "deploy did not reach v2: $out"
[ "$(errors)" -ge 20 ] || die "v2 did not produce errors"
pass "v2 deployed and failing as designed"

out=$(call rollback '{"reason":"smoke test"}')
[ "$(echo "$out" | jq -r .verified)" = true ] || die "rollback not verified: $out"
[ "$(errors)" -le 2 ] || die "errors continued after rollback"
pass "rollback restored v1"

out=$(call rollback)
[ "$(echo "$out" | jq -r .noop)" = true ] || die "second rollback was not a noop: $out"
pass "rollback is idempotent"
