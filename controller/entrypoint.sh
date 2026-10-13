#!/bin/sh
# Start gunicorn, wrapped by the New Relic agent only when a real license key is set.
set -eu

# One worker: the action lock and history live in process memory.
GUNICORN="gunicorn --workers 1 --threads 4 --timeout 200 --bind 0.0.0.0:5001 controller:app"

key="${NEW_RELIC_LICENSE_KEY:-}"
case "$key" in
  ""|REPLACE_VIA_ENV|your_license_key_here)
    echo "NEW_RELIC_LICENSE_KEY not set: starting without the APM agent"
    exec $GUNICORN
    ;;
esac

export NEW_RELIC_APP_NAME="${NEW_RELIC_APP_NAME:-workflow-automation-controller}"
export NEW_RELIC_DISTRIBUTED_TRACING_ENABLED=true
export NEW_RELIC_APPLICATION_LOGGING_ENABLED=true
export NEW_RELIC_APPLICATION_LOGGING_FORWARDING_ENABLED=true
export NEW_RELIC_LABELS="project:wfa;role:controller"
exec newrelic-admin run-program $GUNICORN
