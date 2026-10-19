#!/bin/sh
# Run the load generator, wrapped by the New Relic agent only when a real license key is set.
set -eu

key="${NEW_RELIC_LICENSE_KEY:-}"
case "$key" in
  ""|REPLACE_VIA_ENV|your_license_key_here)
    echo "NEW_RELIC_LICENSE_KEY not set: starting without the APM agent"
    exec python loadgen.py
    ;;
esac

export NEW_RELIC_APP_NAME="${NEW_RELIC_APP_NAME:-wfa-loadgen}"
export NEW_RELIC_DISTRIBUTED_TRACING_ENABLED=true
export NEW_RELIC_LABELS="project:wfa;role:loadgen"
exec newrelic-admin run-program python loadgen.py
