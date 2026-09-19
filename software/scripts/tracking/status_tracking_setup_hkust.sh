#!/usr/bin/env bash
set -euo pipefail

ROOT=/mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/tracking_deployment

case "$ROOT" in
  /mnt/slurmfs-4090node3/user_data/aiwei/lianaiwei/*) ;;
  *) printf 'Refusing out-of-bounds root: %s\n' "$ROOT" >&2; exit 1 ;;
esac

printf '[queue]\n'
squeue -u aiwei -h -o '%i\t%j\t%t\t%M\t%R'
printf '\n[status]\n'
cat "$ROOT/setup.status" 2>/dev/null || printf 'not-started\n'

run_dir="$(find "$ROOT/runs" -mindepth 1 -maxdepth 1 -type d -name 'setup_*' -print 2>/dev/null | sort | tail -1)"
[[ -n "$run_dir" ]] || exit 0
printf '\n[run]\n%s\n' "$run_dir"
cat "$run_dir/resources.tsv" 2>/dev/null || true

printf '\n[first-failures]\n'
for log in "$run_dir"/*.log; do
  [[ -f "$log" ]] || continue
  first="$(grep -nEm1 'Traceback|ERROR|Error:|error:|FAILED|Exception|No matching distribution|ModuleNotFound' "$log" || true)"
  [[ -n "$first" ]] && printf '%s\t%s\n' "$(basename "$log")" "$first"
done

printf '\n[results]\n'
for result in "$run_dir"/*.result; do
  [[ -f "$result" ]] || continue
  printf -- '-- %s --\n' "$(basename "$result")"
  cat "$result"
done
