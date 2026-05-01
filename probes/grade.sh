#!/usr/bin/env bash
# Reads OMB's per-second JSON output and prints:
#   - max consecutive seconds at zero produce rate
#   - max consecutive seconds at zero consume rate
#   - total produce/consume errors
#   - p50 / p99 produce latency
#
# Treats any 1-second bucket where producePublishRate==0 as a "gap".
# A gap > 30 s is automatically flagged as a downtime fail.
#
#   ./grade.sh /var/log/omb/probe.csv

set -euo pipefail

INPUT=${1:?usage: $0 <omb-output.json>}

if [[ ! -s "$INPUT" ]]; then
  echo "input file empty or missing: $INPUT" >&2
  exit 2
fi

# OMB's output is line-delimited JSON-ish; jq slurps and processes.
jq -s '
  def gaps(stream): [stream | . == 0] | reduce .[] as $z (
    {cur: 0, max: 0};
    if $z then {cur: (.cur + 1), max: ([(.cur + 1), .max] | max)}
    else {cur: 0, max: .max}
    end
  ) | .max;

  {
    total_produce_errors: ([.[].producerErrorRate // 0] | add),
    total_consume_errors: ([.[].consumeErrorRate // 0] | add),
    max_produce_zero_seconds: gaps(.[].publishRate // 0),
    max_consume_zero_seconds: gaps(.[].consumeRate // 0),
    p50_produce_latency_ms: ([.[].publishLatency50pct // empty] | sort | .[length/2|floor]),
    p99_produce_latency_ms: ([.[].publishLatency99pct // empty] | sort | .[(length*0.99|floor)])
  } as $r
  | $r,
    if $r.max_produce_zero_seconds > 30 or $r.total_produce_errors > 0 then
      "FAIL: produce gap=\($r.max_produce_zero_seconds)s, errors=\($r.total_produce_errors)"
    else "PASS: produce" end,
    if $r.max_consume_zero_seconds > 30 or $r.total_consume_errors > 0 then
      "FAIL: consume gap=\($r.max_consume_zero_seconds)s, errors=\($r.total_consume_errors)"
    else "PASS: consume" end
' "$INPUT"
