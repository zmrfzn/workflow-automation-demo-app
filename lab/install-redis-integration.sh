#!/bin/bash
# Optional: add the New Relic Redis integration (nri-redis) so the Redis container reports
# RedisSample metrics. Redis is not needed for the rest of the lab; skip this if it fails.
#
# Follows https://docs.newrelic.com/docs/infrastructure/host-integrations/host-integrations-list/redis/redis-integration
# (Linux: install nri-redis, create redis-config.yml, the agent picks it up).
#
# Needs the infrastructure agent (run lab/install-agents.sh first) and the stack running, because
# docker-compose.yml publishes Redis on 127.0.0.1:6379.
# DRY_RUN=1 prints the configuration and changes nothing.
set -euo pipefail

CONFIG_DIR=/etc/newrelic-infra/integrations.d
CONFIG_FILE="$CONFIG_DIR/redis-config.yml"
REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"

config() {
  cat <<EOF
integrations:
  - name: nri-redis
    env:
      METRICS: true
      HOSTNAME: $REDIS_HOST
      PORT: $REDIS_PORT
      REMOTE_MONITORING: true
    interval: 15s
    labels:
      environment: lab
      project: wfa

  - name: nri-redis
    env:
      INVENTORY: true
      HOSTNAME: $REDIS_HOST
      PORT: $REDIS_PORT
      REMOTE_MONITORING: true
    interval: 60s
    labels:
      environment: lab
      project: wfa
    inventory_source: config/redis
EOF
}

if [ "${DRY_RUN:-0}" = "1" ]; then
  config
  exit 0
fi

fail() { echo "Skipping the Redis integration: $1" >&2; echo "Redis monitoring is optional. The lab works without it." >&2; exit 1; }

systemctl list-unit-files newrelic-infra.service >/dev/null 2>&1 \
  && systemctl list-unit-files newrelic-infra.service | grep -q newrelic-infra \
  || fail "the infrastructure agent is not installed. Run ./lab/install-agents.sh first."

echo "==> Checking Redis answers on $REDIS_HOST:$REDIS_PORT"
if ! (exec 3<>"/dev/tcp/$REDIS_HOST/$REDIS_PORT") 2>/dev/null; then
  fail "nothing is listening on $REDIS_HOST:$REDIS_PORT. Run ./lab/start.sh first."
fi

if dpkg -s nri-redis >/dev/null 2>&1; then
  echo "==> nri-redis is already installed"
else
  echo "==> Installing nri-redis"
  sudo apt-get install -y nri-redis || fail "could not install nri-redis from the New Relic package repository."
fi

echo "==> Writing $CONFIG_FILE"
sudo mkdir -p "$CONFIG_DIR"
config | sudo tee "$CONFIG_FILE" >/dev/null

echo "==> Restarting the infrastructure agent"
sudo systemctl restart newrelic-infra
sleep 3
systemctl is-active newrelic-infra

echo
echo "Done. Redis data can take a couple of minutes to appear. Check it with:"
echo "  SELECT count(*) FROM RedisSample SINCE 10 minutes ago"
