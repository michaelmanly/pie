#!/usr/bin/env bash
# The RunPod pod that is the CUDA runner: start it before the GPU job, stop
# it after. Needs RUNPOD_API_KEY and RUNPOD_POD_ID; in Actions, stop also
# needs GH_TOKEN to see whether another run is using the pod.
#
#   runpod.sh start | stop | status
set -euo pipefail
api="https://api.runpod.io/v2/pods/${RUNPOD_POD_ID:?}"
call() {\n  local method="$1" path="$2"\n  shift 2\n  curl -sS --fail-with-body -X "$method" -H "Authorization: Bearer ${RUNPOD_API_KEY:?}" -H "Content-Type: application/json" "$@" "$api$path"\n}\naction() { call POST /action --data "{\"action\":\"$1\"}"; }
status() { call GET "" | jq -r '"\(.status) gpu=\(.gpu.id // "-") uptime=\(.runtime.uptime // 0)s"'; }
case "${1:?start|stop|status}" in
  status) status ;;
  start)
    # A stopped pod resumes only when its host has the GPU free. RunPod answers
    # 500 while it does not: keep asking for a while, then say so and leave
    # `up=false` for the workflow, which skips the CUDA job instead of failing.
    up() { [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "up=$1" >> "$GITHUB_OUTPUT"; return 0; }
    s=$(status); echo "$s"
    case "$s" in RUNNING*) up true; exit 0 ;; esac
    for attempt in $(seq 1 20); do
      if out=$(action start 2>&1); then
        for _ in $(seq 1 30); do
          s=$(status); echo "$s"
          case "$s" in RUNNING*) up true; exit 0 ;; esac
          sleep 10
        done
      else
        echo "start attempt $attempt: $out" >&2
      fi
      sleep 45
    done
    # a start RunPod accepted late must not keep billing after the run gave up on it
    action stop >/dev/null 2>&1 || true
    echo "::warning::RunPod could not resume pod ${RUNPOD_POD_ID} (no free GPU on its host); the CUDA job is skipped"
    up false ;;
  stop)
    # Another run's GPU job may be queued for or on the pod; that run's own
    # stop step turns it off.
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
      for run in $(gh api "repos/$GITHUB_REPOSITORY/actions/runs?per_page=30" \
          -q ".workflow_runs[] | select(.id != $GITHUB_RUN_ID and (.status == \"queued\" or .status == \"in_progress\")) | .id"); do
        if gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run/jobs" \
            -q '.jobs[] | select(.name == "cuda: serve on hardware" and .status != "completed") | .id' | grep -q .; then
          echo "run $run is on the pod; leaving it up"; exit 0
        fi
      done
    fi
    action stop >/dev/null; echo "pod ${RUNPOD_POD_ID} stopped" ;;
  *) echo "usage: $0 start|stop|status" >&2; exit 2 ;;
esac
