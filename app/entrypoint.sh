#!/bin/sh
# Start gunicorn, wrapped by the New Relic agent only when a real license key is set.
set -eu

GUNICORN="gunicorn --workers 2 --threads 4 --timeout 30 --bind 0.0.0.0:5000 app:app"

key="${NEW_RELIC_LICENSE_KEY:-}"
case "$key" in
  ""|REPLACE_VIA_ENV|your_license_key_here)
    echo "NEW_RELIC_LICENSE_KEY not set: starting without the APM agent"
    exec $GUNICORN
    ;;
esac

export NEW_RELIC_APP_NAME="${NEW_RELIC_APP_NAME:-workflow-automation-app}"
export NEW_RELIC_DISTRIBUTED_TRACING_ENABLED=true
export NEW_RELIC_APPLICATION_LOGGING_ENABLED=true
export NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED=true
export NEW_RELIC_APPLICATION_LOGGING_METRICS_ENABLED=true
export NEW_RELIC_LABELS="release:${APP_RELEASE:-v1}"
exec newrelic-admin run-program $GUNICORN
