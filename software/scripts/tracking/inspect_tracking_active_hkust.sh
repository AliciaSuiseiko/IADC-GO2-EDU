#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment

printf '[queue]\n'
squeue -u aiwei -h -o '%i\t%j\t%t\t%M\t%R'
printf '\n[sequencer]\n'
if [[ -f "$ROOT/status/sequencer.pid" ]]; then
  pid="$(cat "$ROOT/status/sequencer.pid")"
  printf 'pid=%s\n' "$pid"
  ps -p "$pid" -o pid,etime,stat,cmd || true
fi
cat "$ROOT/status/sequencer.status" 2>/dev/null || true
tail -80 "$ROOT/logs/sequencer_20260831.log" 2>/dev/null || true

printf '\n[full-pipeline-sequencer]\n'
if [[ -f "$ROOT/status/full_pipeline_sequencer.pid" ]]; then
  pid="$(cat "$ROOT/status/full_pipeline_sequencer.pid")"
  printf 'pid=%s\n' "$pid"
  ps -p "$pid" -o pid,etime,stat,cmd || true
fi
cat "$ROOT/status/full_pipeline_sequencer.status" 2>/dev/null || true
tail -80 "$ROOT/logs/full_pipeline_sequencer_20260831.log" 2>/dev/null || true

printf '\n[project-status]\n'
for project in dap oavat omnitrack lhvln sam3 omnitrack_model oavat_unreal lhvln_habitat; do
  printf -- '-- %s --\n' "$project"
  cat "$ROOT/status/$project.status" 2>/dev/null || printf 'not-started\n'
done

printf '\n[recent-slurm-logs]\n'
find "$ROOT/logs" -maxdepth 1 -type f \
  \( -name '*smoke-*.out' -o -name 'omni-model-*.out' -o -name 'oavat-unreal-*.out' \
     -o -name 'lhvln-habitat-*.out' \) -printf '%T@\t%p\n' \
  | sort -nr | head -8 | cut -f2- | while IFS= read -r log; do
      printf -- '-- %s --\n' "$(basename "$log")"
      tail -30 "$log"
    done

printf '\n[environments-and-models]\n'
du -sh "$ROOT"/envs/* "$ROOT"/models/* "$ROOT"/datasets/* "$ROOT"/runtime/* 2>/dev/null || true
printf '\n[filesystem]\n'
df -h "$ROOT"
