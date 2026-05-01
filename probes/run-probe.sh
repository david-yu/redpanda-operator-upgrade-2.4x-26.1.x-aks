#!/usr/bin/env bash
# Wrapper that starts the OMB benchmark and tees stdout/stderr to a
# timestamped log file. Designed to run inside a tmux session for the
# duration of the upgrade.
#
#   ./run-probe.sh \
#     --driver  drivers/redpanda.yaml \
#     --workload workloads/upgrade-10mbps.yaml \
#     --output  /var/log/omb/probe.csv

set -euo pipefail

DRIVER=""
WORKLOAD=""
OUT=/var/log/omb/probe.csv

while [[ $# -gt 0 ]]; do
  case "$1" in
    --driver)   DRIVER=$2;   shift 2;;
    --workload) WORKLOAD=$2; shift 2;;
    --output)   OUT=$3;      shift 2;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

: "${DRIVER:?--driver required}"
: "${WORKLOAD:?--workload required}"

mkdir -p "$(dirname "$OUT")"
TS=$(date -u +%FT%TZ)
LOG=/var/log/omb/probe-$TS.log

echo "==> probe started at $TS"
echo "==> driver=$DRIVER workload=$WORKLOAD output=$OUT log=$LOG"

# OMB's `bin/benchmark` writes per-period metrics to stdout in JSON; we
# capture both the summary log and a CSV-friendly per-second feed.
exec > >(tee -a "$LOG")
exec 2>&1

bin/benchmark --drivers "$DRIVER" --workers '' --output "$OUT" "$WORKLOAD"
