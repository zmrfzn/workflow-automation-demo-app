#!/bin/bash
# Install New Relic on the host with the guided installer, using the keys saved in .env.
# The APM agent already ships inside the shop-api image and starts when a license key is set.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo ".env is missing. Run lab/wire-credentials.sh first." >&2; exit 1; }
set -a; . ./.env; set +a

if systemctl is-active --quiet newrelic-infra 2>/dev/null; then
  echo "Infrastructure agent is already running."
  exit 0
fi

echo "Installing the New Relic CLI..."
curl -Ls https://download.newrelic.com/install/newrelic-cli/scripts/install.sh | bash </dev/null

echo "Running the guided install..."
sudo NEW_RELIC_API_KEY="$NEW_RELIC_API_KEY" NEW_RELIC_ACCOUNT_ID="$NEW_RELIC_ACCOUNT_ID" \
  /usr/local/bin/newrelic install -y --tag env:lab </dev/null

echo "New Relic installed on this host."
