#!/bin/sh
# ===========================================================================
# report-timings.sh — print a per-stage duration table from the run's timing
# log (written by record-timing.sh at the start of each key workflow step).
#
# Stages run strictly sequentially, so each stage's duration is the gap
# between its marker and the next marker. TOTAL is the span of the whole log.
#
# Usage: sh scripts/report-timings.sh
# ===========================================================================
TIMING_LOG="${TIMING_LOG:-.iac-timings.log}"

if [ ! -f "$TIMING_LOG" ]; then
  echo "No timings recorded (log '$TIMING_LOG' absent)"
  exit 0
fi

awk '
{
  stages[NR] = $1
  times[NR]  = $2
}
END {
  printf "%-32s %12s\n", "STAGE", "DURATION"
  printf "%-32s %12s\n", "-----", "--------"
  for (i = 1; i <= NR; i++) {
    if (i < NR) dur = times[i + 1] - times[i]
    else        dur = times[NR] - times[NR - 1]
    printf "%-32s %8.1fs\n", stages[i], dur
  }
  printf "%-32s %8.1fs\n", "TOTAL", times[NR] - times[1]
}' "$TIMING_LOG"
