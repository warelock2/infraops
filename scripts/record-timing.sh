#!/bin/sh
# ===========================================================================
# record-timing.sh — append a timestamp marker for a workflow stage.
#
# Called at the START of key workflow steps. The markers accumulate in a
# shared log inside the runner workspace, and the final workflow step
# (report-timings.sh) prints a per-stage duration table. Because the stages
# run strictly sequentially, the duration of a stage is the gap between its
# marker and the next one.
#
# Usage: sh scripts/record-timing.sh <stage-name>
# ===========================================================================
STAGE="${1:?usage: record-timing.sh <stage-name>}"
TIMING_LOG="${TIMING_LOG:-.iac-timings.log}"
echo "$STAGE $(date +%s.%N)" >> "$TIMING_LOG"
