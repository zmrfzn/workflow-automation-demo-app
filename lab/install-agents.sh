#!/bin/bash
# Install New Relic on the host with the guided installer, using the keys saved in .env.
# Run it in a terminal: the installer is interactive so you can skip detected items
# (for example Redis) when it asks. The APM agent already ships inside the shop-api
# image and starts when a license key is set.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo ".env is missing. Run lab/wire-credentials.sh first." >&2; exit 1; }
[ -t 0 ] && [ -t 1 ] || { echo "Run this in a terminal; the installer asks questions." >&2; exit 1; }
set -a; . ./.env; set +a

if systemctl is-active --quiet newrelic-infra 2>/dev/null; then
  echo "Infrastructure agent is already running."
  exit 0
fi

echo "==> Installing the New Relic CLI"
curl -L https://download.newrelic.com/install/newrelic-cli/scripts/install.sh | bash

echo
echo "==> Starting the guided install (skip Redis if it offers it; the optional Redis step adds it)"
sudo NEW_RELIC_API_KEY="$NEW_RELIC_API_KEY" NEW_RELIC_ACCOUNT_ID="$NEW_RELIC_ACCOUNT_ID" \
  /usr/local/bin/newrelic install --tag env:lab

echo
echo "==> Done. Host agent status:"
systemctl is-active newrelic-infra || true
echo
echo "Optional, after ./lab/start.sh: ./lab/install-redis-integration.sh monitors the Redis container."
