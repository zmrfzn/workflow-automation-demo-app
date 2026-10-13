#!/bin/bash
# Install the New Relic infrastructure agent on the host. The APM agent already ships
# inside the shop-api image and is switched on by the license key in .env.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

if systemctl is-active --quiet newrelic-infra 2>/dev/null; then
  echo "Infrastructure agent is already running."
  exit 0
fi

echo "Installing the New Relic CLI..."
curl -fsSL https://download.newrelic.com/install/newrelic-cli/scripts/install.sh | bash </dev/null

echo "Installing the infrastructure agent..."
NEW_RELIC_API_KEY="$NEW_RELIC_API_KEY" NEW_RELIC_ACCOUNT_ID="$NEW_RELIC_ACCOUNT_ID" \
  NEW_RELIC_REGION=US \
  newrelic install -n infrastructure-agent-installer -y </dev/null

echo "Infrastructure agent installed."
