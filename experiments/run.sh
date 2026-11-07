#!/usr/bin/env bash
#
# Compare the "circuits" and "circuits_alt" circuit sets on the base (A-F)
# devices. Every circuit batch of both sets (read from experiments/data/in/) is
# run for a range of seeds, and the summary results (depth, teledata, telegate,
# swaps, deadlocks, success, runtime) are collected into:
#
#   <out_dir>/telesabre_results.json       (circuits     on A-F)
#   <out_dir>/telesabre_results_alt.json   (circuits_alt on A-F)
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
# The best run of each circuit is the successful run with the lowest
# inter_core (teledata + telegate), ties broken by fewest swaps.
#
# Usage:
#   experiments/run_experiment.sh [config.json] [num_seeds] [start_seed] [out_dir]
#
# Defaults: configs/default.json, 5 seeds, start seed 0, out dir experiments/data/out
#
# Optional: ONLY_BATCHES="qasm_25 qasm_64" restricts the run to those batches.
#
# Requires jq and perl (both ship with macOS). Works with bash 3.2.
#
set -euo pipefail

# Run from the repo root so the relative paths below work from any directory.
cd "$(dirname "$0")/.."

CONFIG=${1:-configs/default.json}
NUM_SEEDS=${2:-5}
START_SEED=${3:-0}
OUT_DIR=${4:-experiments/data/out}

BIN=./telesabre
IN_DIR=experiments/data/in

# Circuit sets to compare (subdirectories of $IN_DIR). The first is the baseline.
CIRCUIT_SETS=(circuits circuits_alt)

# Output file name for a circuit set: telesabre_results<suffix>.json
out_suffix() { # out_suffix <set_name>
    case $1 in
        circuits)  echo "" ;;
        circuits_*) echo "_${1#circuits_}" ;;
        *)         echo "_$1" ;;
    esac
}

# "label  device" -- each label is a qasm_* subdirectory of every circuit set.
BATCHES=(
    "qasm_25  devices/A.json"
    "qasm_64  devices/B.json"
    "qasm_80  devices/C.json"
    "qasm_95  devices/D.json"
    "qasm_200 devices/E.json"
    "qasm_360 devices/F.json"
)
if [[ -n "${ONLY_BATCHES:-}" ]]; then
    kept=()
    for entry in "${BATCHES[@]}"; do
        label=${entry%% *}
        for want in $ONLY_BATCHES; do
            [[ "$label" == "$want" ]] && kept+=("$entry")
        done
    done
    ((${#kept[@]} > 0)) || { echo "Error: ONLY_BATCHES matched no batch." >&2; exit 1; }
    BATCHES=("${kept[@]}")
fi

[[ -x "$BIN" ]] || { echo "Error: $BIN not found; compile it first (see README)." >&2; exit 1; }
[[ -f "$CONFIG" ]] || { echo "Error: config $CONFIG not found." >&2; exit 1; }
for set_name in "${CIRCUIT_SETS[@]}"; do
    [[ -d "$IN_DIR/$set_name" ]] || { echo "Error: $IN_DIR/$set_name not found." >&2; exit 1; }
done
mkdir -p "$OUT_DIR"

TMPDIR_RUN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_RUN"' EXIT
TMP_CONFIG="$TMPDIR_RUN/config.json"

now() { perl -MTime::HiRes=time -e 'printf "%.6f", time'; }

bar() { # bar <done> <total> [width]
    local done=$1 total=$2 width=${3:-24} filled i s=""
    filled=$(( total > 0 ? width * done / total : width ))
    for ((i = 0; i < width; i++)); do
        if ((i < filled)); then s+="#"; else s+="-"; fi
    done
    printf "[%s] %d/%d" "$s" "$done" "$total"
}

loader() { # loader <prefix> <done> <total> <extra>
    printf "\r\033[K  %s seeds %s %s" "$1" "$(bar "$2" "$3" 10)" "$4"
    if (("$2" >= "$3")); then printf "\n"; fi
}

# Run one seed of one circuit on one device and print a single JSON object.
run_seed() { # run_seed <device> <circuit> <seed>
    local device=$1 circuit=$2 seed=$3 t0 t1 status=0 summary
    local failed success depth teledata telegate swaps deadlocks

    jq --argjson seed "$seed" '.config.seed = $seed' "$CONFIG" > "$TMP_CONFIG"

    t0=$(now)
    # Stream the (very verbose) output straight into awk, keeping only the
    # number of failed attempts and the final Result block.
    summary=$(
        { "$BIN" "$TMP_CONFIG" "$device" "$circuit" 2>/dev/null || echo "__EXIT_NONZERO__"; } |
        awk '
            /__EXIT_NONZERO__/                  { crashed = 1 }
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
                printf "%d %d %s %s %s %s %s %s\n", crashed, failed, success,
                    (depth == "" ? "null" : depth), (teledata == "" ? "null" : teledata),
                    (telegate == "" ? "null" : telegate), (swaps == "" ? "null" : swaps),
                    (deadlocks == "" ? "null" : deadlocks)
            }'
    )
    t1=$(now)
    read -r status failed success depth teledata telegate swaps deadlocks <<< "$summary"

    jq -nc \
        --argjson seed "$seed" --argjson failed "$failed" --argjson success "$success" \
        --argjson crashed "$status" \
        --argjson depth "$depth" --argjson teledata "$teledata" \
        --argjson telegate "$telegate" --argjson swaps "$swaps" \
        --argjson deadlocks "$deadlocks" \
        --argjson runtime "$(perl -e "printf '%.6f', $t1 - $t0")" '
        { seed: $seed,
          effective_seed: (if $success then $seed + $failed else null end),
          failed_attempts: $failed,
          success: $success,
          crashed: ($crashed == 1),
          depth: $depth, teledata: $teledata, telegate: $telegate,
          inter_core: (if $teledata == null or $telegate == null then null else $teledata + $telegate end),
          swaps: $swaps, deadlocks: $deadlocks,
          runtime_s: $runtime }'
}

# Run all seeds for one circuit and print the per-file JSON result.
run_file() { # run_file <device> <circuit> <progress>
    local device=$1 circuit=$2 progress=$3 name tag runs_file i seed run rt total_rt
    name=$(basename "$circuit")
    tag="$progress $name"
    runs_file="$TMPDIR_RUN/runs.jsonl"
    : > "$runs_file"

    for ((i = 0; i < NUM_SEEDS; i++)); do
        seed=$((START_SEED + i))
        loader "$tag" "$i" "$NUM_SEEDS" "running seed $seed..." >&2
        run=$(run_seed "$device" "$circuit" "$seed")
        echo "$run" >> "$runs_file"
        rt=$(jq -r '.runtime_s' <<< "$run")
        if ((i + 1 < NUM_SEEDS)); then
            loader "$tag" "$((i + 1))" "$NUM_SEEDS" "$(printf 'seed %d took %.2fs' "$seed" "$rt")" >&2
        fi
    done
    total_rt=$(jq -s 'map(.runtime_s) | add' "$runs_file")
    loader "$tag" "$NUM_SEEDS" "$NUM_SEEDS" "$(printf 'done in %.2fs' "$total_rt")" >&2

    jq -s \
        --arg file "$name" --arg path "$circuit" --arg device "$device" \
        --arg arch "$(basename "$device" .json)" --argjson num_seeds "$NUM_SEEDS" '
        (map(select(.success and .inter_core != null))) as $ok
        | ($ok | if length > 0 then min_by([.inter_core, .swaps]) else null end) as $best
        | { file: $file,
            path: $path,
            arch: $arch,
            device: $device,
            num_seeds: $num_seeds,
            best_seed: ($best.seed // null),
            best: (if $best == null then null else
                    { seed: $best.seed,
                      effective_seed: $best.effective_seed,
                      teledata: $best.teledata,
                      telegate: $best.telegate,
                      inter_core: $best.inter_core,
                      swaps: $best.swaps,
                      depth: $best.depth,
                      deadlocks: $best.deadlocks,
                      success: $best.success,
                      runtime_s: $best.runtime_s } end),
            num_successful_runs: ($ok | length),
            all_successful: all(.[]; .success),
            runs: . }' "$runs_file"
}

shopt -s nullglob

# Count files over all sets for the overall progress bar.
total=0
for set_name in "${CIRCUIT_SETS[@]}"; do
    for entry in "${BATCHES[@]}"; do
        read -r label _ <<< "$entry"
        files=("$IN_DIR/$set_name/$label"/*.qasm)
        total=$((total + ${#files[@]}))
    done
done
done_count=0
pass_no=0

for set_name in "${CIRCUIT_SETS[@]}"; do
    pass_no=$((pass_no + 1))
    suffix=$(out_suffix "$set_name")
    echo "===== Pass $pass_no/${#CIRCUIT_SETS[@]}: telesabre_results$suffix ($set_name on A-F) ====="
    echo

    batches_file="$TMPDIR_RUN/batches_$set_name.jsonl"
    : > "$batches_file"

    for entry in "${BATCHES[@]}"; do
        read -r label device <<< "$entry"
        qasm_dir="$IN_DIR/$set_name/$label"
        files=("$qasm_dir"/*.qasm)
        echo "[$set_name/$label] $(basename "$device" .json): ${#files[@]} qasm files in $qasm_dir"
        echo

        results_file="$TMPDIR_RUN/results.jsonl"
        : > "$results_file"
        for circuit in "${files[@]}"; do
            done_count=$((done_count + 1))
            progress="overall $(bar "$done_count" "$total") |"
            result=$(run_file "$device" "$circuit" "$progress")
            echo "$result" >> "$results_file"

            jq -r '
                if .best then
                    "    best seed=\(.best.seed)  inter-core=\(.best.inter_core) (teledata=\(.best.teledata) telegate=\(.best.telegate))  swaps=\(.best.swaps)  depth=\(.best.depth)"
                else
                    "    no successful run"
                end,
                (.runs[] | select(.crashed) | "    seed \(.seed) CRASHED (telesabre exited non-zero)")
            ' <<< "$result"
        done

        jq -sc --arg batch "$label" --arg qasm_dir "$qasm_dir" --arg device "$device" \
            --arg arch "$(basename "$device" .json)" \
            '{ batch: $batch, qasm_dir: $qasm_dir, arch: $arch, device: $device, results: . }' \
            "$results_file" >> "$batches_file"
        echo
    done

    out_path="$OUT_DIR/telesabre_results$suffix.json"
    jq -s \
        --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg variant "$set_name" \
        --arg config_path "$CONFIG" \
        --argjson num_seeds "$NUM_SEEDS" --argjson start_seed "$START_SEED" \
        --slurpfile config "$CONFIG" '
        { generated_at: $generated_at,
          variant: $variant,
          config_path: $config_path,
          config: $config[0].config,
          num_seeds: $num_seeds,
          start_seed: $start_seed,
          batches: . }' "$batches_file" > "$out_path.tmp"
    mv "$out_path.tmp" "$out_path"
    echo "Wrote results to $out_path"
    echo
done
