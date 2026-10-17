#!/usr/bin/env bash
# Run a concurrency sweep against the decode-only llm-d setup.
# Requests go through the EPP gateway. Metrics are collected from each decode engine
# through its NodePort. Create the metrics services first if needed.
# Run this from a machine that can reach the gateway, preferably not the GPU node.
set -euo pipefail

BASE_URL="${BASE_URL:-http://10.68.0.39:30516}"                 # quickstart-epp-np
MODEL="${MODEL:-coolthor/gemma-4-12B-it-FP8-dynamic}"           # must match --served-model-name on the server
TOKENIZER="${TOKENIZER:-google/gemma-4-12b-it}"                 # official base vocab == server checkpoint vocab
OUT_DIR="${OUT_DIR:-gemma-4-12B_decode}"
LEVELS="1 2 4 8 16 32 64 128"
NODE_IP="${NODE_IP:-10.68.0.39}"                                # node where NodePort metrics live
METRICS_INTERVAL="${METRICS_INTERVAL:-1}"                       # seconds per /metrics poll
# Each entry is a NodePort followed by its pod tag.
METRIC_PORTS="${METRIC_PORTS:-30500 pod0 30501 pod1}"
METRICS_DIR="$OUT_DIR/metrics"
DRY_RUN="${DRY_RUN:-0}"
DRY_SECONDS="${DRY_SECONDS:-5}"

mkdir -p "$OUT_DIR" "$METRICS_DIR"

# Metrics capture
# Poll each decode engine through its own NodePort while the benchmarks run.
# Save the raw metrics so they can be processed later.

# Each pod has its own capture process, so one failed scrape does not stop the others.
# Failed or partial scrapes are not added to the raw file.
# curl errors are saved separately to help diagnose failures.

CAPTURE_PIDS=()
poll_engine() {   # poll_engine <nodePort> <tag>
  local p="$1" tag="$2" i=0 rc tmp="$METRICS_DIR/.${2}.scrape.tmp"
  touch "$METRICS_DIR/${tag}_metrics.raw"   # exist even if every scrape fails
  while :; do
    i=$((i + 1))
    rc=0
    # scrape to a temp file first: a failed/partial scrape must not append
    # anything to the .raw, or the next good block would be glued onto a
    # truncated one and the parser could not tell them apart.
    curl -sS --max-time 2 "http://$NODE_IP:$p/metrics" \
      > "$tmp" 2>>"$METRICS_DIR/curl_errors.log" || rc=$?
    if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
      cat "$tmp" >> "$METRICS_DIR/${tag}_metrics.raw"
      echo >> "$METRICS_DIR/${tag}_metrics.raw"
      echo "$(date -u +%FT%TZ) $tag $i ok" >> "$METRICS_DIR/capture.log"
    else
      [ "$rc" -eq 0 ] && rc=66   # curl "succeeded" but body was empty
      echo "$(date -u +%FT%TZ) $tag $i FAIL rc=$rc (no block written)" >> "$METRICS_DIR/capture.log"
    fi
    sleep "$METRICS_INTERVAL"
  done
}
start_capture() {
  echo "capture: start"
  echo "start $(date -u +%FT%TZ)" > "$METRICS_DIR/capture.log"
  : > "$METRICS_DIR/curl_errors.log"
  local p tag
  set -- $METRIC_PORTS
  while [ "$#" -ge 2 ]; do
    p="$1"; tag="$2"
    poll_engine "$p" "$tag" &
    CAPTURE_PIDS+=("$!")
    shift 2
  done
  if command -v nvidia-smi >/dev/null 2>&1; then
    (
      while :; do
        sleep 5
        echo -n "$(date -u +%FT%TZ)," >> "$METRICS_DIR/gpu.csv"
        nvidia-smi --query-gpu=index,utilization.gpu,memory.used,power.draw,temperature.gpu \
          --format=csv,noheader,nounits >> "$METRICS_DIR/gpu.csv" 2>>"$METRICS_DIR/curl_errors.log" \
          || echo "$(date -u +%FT%TZ) nvidia-smi FAIL rc=$?" >> "$METRICS_DIR/capture.log"
      done
    ) &
    CAPTURE_PIDS+=("$!")
  fi
}
stop_capture() {
  if [ ${#CAPTURE_PIDS[@]} -gt 0 ]; then
    local pid
    for pid in "${CAPTURE_PIDS[@]}"; do
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    done
    CAPTURE_PIDS=()
    local t
    for t in "$METRICS_DIR"/.*.scrape.tmp; do
      [ -e "$t" ] && rm -f "$t"
    done
    echo "capture: stopped" >> "$METRICS_DIR/capture.log"
    echo "end $(date -u +%FT%TZ)" >> "$METRICS_DIR/capture.log"
  fi
}
trap stop_capture EXIT

# Reset the prefix cache directly on each engine. This route requires dev mode.
# The EPP gateway has no route for resetting the whole pool.

reset_all() {
  local p tag
  set -- $METRIC_PORTS
  while [ "$#" -ge 2 ]; do
    p=$1; tag=$2
    curl -s --max-time 5 -o /dev/null -w "$tag reset: %{http_code}\n" -X POST "http://$NODE_IP:$p/reset_prefix_cache" || echo "$tag reset: 000"
    shift 2
  done
}

set -- $METRIC_PORTS
while [ "$#" -ge 2 ]; do
  CODE=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" -X POST "http://$NODE_IP:$1/reset_prefix_cache" || echo 000)
  if [ "$CODE" != "200" ]; then
    echo "ERROR: POST http://$NODE_IP:$1/reset_prefix_cache returned $CODE."
    echo "  Restart the engine with VLLM_SERVER_DEV_MODE=1 to enable it. Without"
    echo "  it the sweep runs with a warm prefix cache and the TTFT curve is wrong."
    exit 1
  fi
  shift 2
done

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: capture only, no benches ($DRY_SECONDS s)."
  start_capture
  sleep "$DRY_SECONDS"
  stop_capture
  ls -la "$METRICS_DIR"
  set -- $METRIC_PORTS
  while [ "$#" -ge 2 ]; do
    echo "${2}_metrics.raw:"; head -c 300 "$METRICS_DIR/${2}_metrics.raw" 2>/dev/null; echo
    shift 2
  done
  exit 0
fi

run () {          # run <tag> <extra args...>
  local tag="$1"; shift
  for N in $LEVELS; do
    if [ -s "$OUT_DIR/${tag}_n${N}.json" ]; then
      echo "=== $tag  concurrency=$N  -- already done, skipping ==="
      continue
    fi
    echo "=== $tag  concurrency=$N ==="
    reset_all
    vllm bench serve \
      --backend openai-chat \
      --base-url "$BASE_URL" \
      --endpoint /v1/chat/completions \
      --model "$MODEL" \
      --tokenizer "$TOKENIZER" \
      --max-concurrency "$N" \
      --num-prompts $(( N * 10 )) \
      --ignore-eos \
      --percentile-metrics ttft,tpot,itl,e2el \
      --metric-percentiles 50,95,99 \
      --save-result \
      --result-dir "$OUT_DIR" \
      --result-filename "${tag}_n${N}.json" \
      "$@"
    sleep 5
  done
}

# Warmup
reset_all
start_capture
vllm bench serve --backend openai-chat --base-url "$BASE_URL" \
  --endpoint /v1/chat/completions --model "$MODEL" --tokenizer "$TOKENIZER" \
  --dataset-name random --random-input-len 1024 --random-output-len 128 \
  --num-prompts 20 --max-concurrency 4 --ignore-eos

# Random workload
# Use a shared 2048-token prefix to test prefix-cache hits.
# Input length is 4096 tokens and output length is 1024 tokens.
run random \
  --dataset-name random \
  --random-input-len 4096 \
  --random-output-len 1024 \
  --random-prefix-len 2048

# ShareGPT workload
# Download this dataset once if it is not already present:
# wget https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json
run sharegpt \
  --dataset-name sharegpt \
  --dataset-path ./ShareGPT_V3_unfiltered_cleaned_split.json \
  --sharegpt-output-len 1024

echo "Done. JSON results are in $OUT_DIR/."
