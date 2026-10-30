#!/bin/bash
# Live view of the traffic generator, for the Loadgen tab: container state, then its logs.
# Survives loadgen stopping, restarting, or not existing yet, and never exits on its own.
set -uo pipefail

cd "$(dirname "$0")/.."
NAME=wfa-loadgen

state() {
  docker inspect "$NAME" --format \
    'state={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}} last_exit={{.State.ExitCode}} oom_killed={{.State.OOMKilled}}' \
    2>/dev/null
}

while true; do
  echo
  echo "== $(date '+%H:%M:%S') loadgen status"
  if ! info=$(state); then
    echo "  $NAME does not exist yet. Run ./lab/start.sh to start the stack."
    sleep 5
    continue
  fi
  echo "  $info"
  if [ "$(docker inspect "$NAME" --format '{{.State.Running}}' 2>/dev/null)" = "true" ]; then
    echo "  Traffic is flowing. One heartbeat line every 10 seconds:"
    echo
    docker logs -f --tail 20 "$NAME" 2>&1
    echo
    echo "  $NAME stopped at $(date '+%H:%M:%S')"
  else
    echo "  Traffic is stopped. Resume it: docker compose start loadgen"
    sleep 5
  fi
  sleep 3
done
