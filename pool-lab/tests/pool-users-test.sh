#!/usr/bin/env bash
# ─────────────────────────────────────────────
# Offline tests for the browser tooling: selenium/pool_users.py (python unittest, fake selenium)
# and provision.sh's `users accept-invites|validate-passwords|reset-passwords` wrappers
# (a fake python records its arguments). No browser, no network, no API key.
# Usage: ./tests/pool-users-test.sh
# ─────────────────────────────────────────────
set -uo pipefail

_HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
check() { if [[ "$2" -eq 0 ]]; then PASS=$(( PASS + 1 )); echo "  ✔ $1"; else FAIL=$(( FAIL + 1 )); echo "  ✖ $1"; fi; }

echo "pool_users.py (python unittest, fake selenium)"
if python3 "$_HERE/pool_users_test.py" >/tmp/pool-users-py.out 2>&1; then
  check "python unit tests: $(grep -E '^Ran ' /tmp/pool-users-py.out)" 0
else
  check "python unit tests" 1
  sed 's/^/    /' /tmp/pool-users-py.out | tail -30
fi

echo "provision.sh browser wrappers"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" /tmp/pool-users-py.out' EXIT
# Run a COPY of provision.sh + lib in a temp dir: provision.sh auto-sources pool-lab/.env, and a
# developer's real .env must never leak into (or be read by) the tests.
mkdir -p "$TMP/kit" && cp -R "$_HERE/../provision.sh" "$_HERE/../lib" "$TMP/kit/"
PROVISION="$TMP/kit/provision.sh"
FAKEPY="$TMP/fakepy"; ARGS="$TMP/args"
cat > "$FAKEPY" <<EOF
#!/usr/bin/env bash
echo "\$@" > "$ARGS"
env | grep -E '^(POOL_EMAIL_PREFIX|POOL_USER_DOMAIN|POOL_USER_COUNT)=' | sort >> "$ARGS"
EOF
chmod +x "$FAKEPY"

# Clean env: no API key, no newrelic CLI on PATH → proves the browser commands need neither.
run() { # run <args...>; env scrubbed of ambient NR/pool settings
  env -i PATH="/usr/bin:/bin" HOME="$TMP" POOL_LAB_PYTHON="${PY:-$FAKEPY}" ${EXTRA_ENV:-} \
    bash "$PROVISION" "$@"
}

rm -f "$ARGS"; EXTRA_ENV="POOL_USER_DOMAIN=example.com POOL_EMAIL_PREFIX=labpool+ POOL_USER_COUNT=5" \
  run users validate-passwords --dry-run --headless >"$TMP/out" 2>&1; rc=$?
check "validate-passwords works with no API key (rc=0)" $rc
check "passes --validate-passwords --headless --dry-run" "$(grep -q -- '--validate-passwords --headless --dry-run' "$ARGS"; echo $?)"
check "exports prefix/domain/count to python" "$(grep -q 'POOL_EMAIL_PREFIX=labpool+' "$ARGS" && grep -q 'POOL_USER_DOMAIN=example.com' "$ARGS" && grep -q 'POOL_USER_COUNT=5' "$ARGS"; echo $?)"

rm -f "$ARGS"; EXTRA_ENV="POOL_USER_DOMAIN=example.com" run users reset-passwords >"$TMP/out" 2>&1; rc=$?
check "reset-passwords maps to --reset-pool-passwords" "$(grep -q -- '--reset-pool-passwords' "$ARGS"; echo $?)"
check "no --dry-run/--headless unless asked" "$(! grep -q -- '--dry-run\|--headless' "$ARGS"; echo $?)"

rm -f "$ARGS"; run users accept-invites --dry-run >"$TMP/out" 2>&1; rc=$?
check "accept-invites needs no POOL_USER_DOMAIN (rc=0)" $rc
check "accept-invites maps to --accept-invites --dry-run" "$(grep -q -- '--accept-invites --dry-run' "$ARGS"; echo $?)"

rm -f "$ARGS"; run users validate-passwords >"$TMP/out" 2>&1; rc=$?
check "validate-passwords without POOL_USER_DOMAIN fails clearly" "$([[ $rc -ne 0 ]] && grep -q 'POOL_USER_DOMAIN' "$TMP/out"; echo $?)"
check "…and never started python" "$([[ ! -f "$ARGS" ]]; echo $?)"

rm -f "$ARGS"; PY="$TMP/does-not-exist" EXTRA_ENV="POOL_USER_DOMAIN=example.com" run users validate-passwords >"$TMP/out" 2>&1; rc=$?
check "missing venv fails with setup instructions" "$([[ $rc -ne 0 ]] && grep -q 'pip install -r requirements.txt' "$TMP/out"; echo $?)"

run users bogus-command >"$TMP/out" 2>&1; rc=$?
check "unknown users subcommand still rejected" "$([[ $rc -ne 0 ]]; echo $?)"
check "usage lists the browser commands" "$(run --help 2>&1 | grep -q 'accept-invites'; echo $?)"

echo ""
echo "passed: $PASS  failed: $FAIL"
[[ $FAIL -eq 0 ]]
