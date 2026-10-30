#!/usr/bin/env bash
#
# Run telesabre over a range of seeds with a fixed config + device + circuit,
# collecting only the summary results (depth, teledata, telegate, swaps,
# deadlocks, success) into a single JSON Lines file.
#
# Only the "seed" value of the config is changed between runs: for each seed a
# temporary copy of the config is written with just .config.seed replaced, so
# the original config file and the C code are left untouched. Results are
# parsed from telesabre's printed "Result:" block.
#
# Note: telesabre retries failed runs internally (up to max_attempts), bumping
# the seed each time. "seed" is the seed we started from; "effective_seed" is
# the seed of the attempt that actually produced the reported result.
#
# Usage:
#   scripts/run_experiment.sh <config.json> <device.json> <circuit.qasm> <num_seeds> [start_seed] [out.jsonl]
#
# Example:
#   scripts/run_experiment.sh configs/default.json devices/G.json \
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

TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT
TMP_CONFIG="$TMPDIR_RUN/config.json"

# Start fresh so re-runs don't append to old data.
: > "$OUT"

for ((i = 0; i < NUM_SEEDS; i++)); do
    seed=$((START_SEED + i))
    echo "Running seed $seed ..."

    # Copy of the config with only the seed changed.
    jq --argjson seed "$seed" '.config.seed = $seed' "$CONFIG" > "$TMP_CONFIG"

    # Stream the (very verbose) output straight into awk, keeping only the
    # number of failed attempts and the final Result block.
    summary=$(
        { "$BIN" "$TMP_CONFIG" "$DEVICE" "$CIRCUIT" 2>/dev/null \
            || echo "  (seed $seed exited non-zero)" >&2; } |
        awk '
            /Telesabre run failed/              { failed++ }
            /^Result:|^Best result/             { in_result = 1 }
            in_result && /^  Depth:/            { depth = $2 }
            in_result && /^  Teledata:/         { teledata = $2 }
            in_result && /^  Telegate:/         { telegate = $2 }
            in_result && /^  Swaps:/            { swaps = $2 }
            in_result && /^  Deadlocks:/        { deadlocks = $2 }
            in_result && /^  Success:/          { success = $2 }
            END {
                if (success == "") success = "false"
                printf "%d %s %s %s %s %s %s\n", failed, success,
                    (depth == "" ? "null" : depth), (teledata == "" ? "null" : teledata),
                    (telegate == "" ? "null" : telegate), (swaps == "" ? "null" : swaps),
                    (deadlocks == "" ? "null" : deadlocks)
            }'
    )
    read -r failed success depth teledata telegate swaps deadlocks <<< "$summary"

    jq -nc \
        --arg circuit "$CIRCUIT" --arg device "$DEVICE" --arg config "$CONFIG" \
        --argjson seed "$seed" --argjson failed "$failed" --argjson success "$success" \
        --argjson depth "$depth" --argjson teledata "$teledata" \
        --argjson telegate "$telegate" --argjson swaps "$swaps" \
        --argjson deadlocks "$deadlocks" '
        { circuit: $circuit, device: $device, config: $config,
          seed: $seed,
          effective_seed: (if $success then $seed + $failed else null end),
          failed_attempts: $failed,
          success: $success,
          depth: $depth, teledata: $teledata, telegate: $telegate,
          inter_core: (if $teledata == null then null else $teledata + $telegate end),
          swaps: $swaps, deadlocks: $deadlocks }' >> "$OUT"
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
