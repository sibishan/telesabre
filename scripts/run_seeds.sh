#!/usr/bin/env bash
#
# Run telesabre over a range of seeds with a fixed device + circuit,
# collecting only the summary results (depth, teledata, telegate, swaps,
# deadlocks, success) into a single JSON Lines file.
#
# Usage:
#   scripts/run_seeds.sh <config.json> <device.json> <circuit.qasm> <num_seeds> [start_seed] [out.jsonl]
#
# Example:
#   scripts/run_seeds.sh configs/default.json devices/G.json \
#       circuits/qasm_25/qft_nativegates_ibm_qiskit_opt3_25.qasm 20
#
set -euo pipefail

CONFIG=${1:?config file required}
DEVICE=${2:?device file required}
CIRCUIT=${3:?circuit file required}
NUM_SEEDS=${4:?number of seeds required}
START_SEED=${5:-0}
OUT=${6:-results.jsonl}

BIN=./telesabre

# Start fresh so re-runs don't append to old data.
: > "$OUT"

for ((i = 0; i < NUM_SEEDS; i++)); do
    seed=$((START_SEED + i))
    echo "Running seed $seed ..."
    # Force one attempt per invocation so the reported result matches this seed,
    # append the summary to $OUT, and silence the verbose progress output.
    "$BIN" "$CONFIG" "$DEVICE" "$CIRCUIT" \
        --seed "$seed" \
        --max_attempts 1 \
        --required_successes 1 \
        --save_report false \
        --results_filename "$OUT" \
        > /dev/null 2>&1 || echo "  (seed $seed exited non-zero)"
done

echo "Done. Per-run results written to $OUT"

# Build a combined JSON report: every run plus the single best run.
# "best" = successful run with the lowest inter_core (teledata + telegate),
# matching how telesabre itself selects its best result.
SUMMARY=${OUT%.jsonl}.json
jq -s '
    { runs: .,
      best_run: ( map(select(.success)) | min_by(.inter_core) ) }
' "$OUT" > "$SUMMARY"

echo "Combined report (runs + best_run) written to $SUMMARY"
echo "Best run:"
jq '.best_run' "$SUMMARY"
