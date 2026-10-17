#!/usr/bin/env bash
# vllm bench serve — concurrency sweep against a remote server.
# Run this from a machine that is NOT the GPU box (or at least a separate process).
set -euo pipefail

BASE_URL="${BASE_URL:-http://10.68.0.39:30616}"
MODEL="${MODEL:-coolthor/gemma-4-12B-it-FP8-dynamic}"          # must match --served-model-name on the server
TOKENIZER="${TOKENIZER:-google/gemma-4-12b-it}"               # official base vocab == server checkpoint vocab
OUT_DIR="${OUT_DIR:-gemma-4-12B_pd_llmd}"
LEVELS="1 2 4 8 16 32 64 128"
NODE_IP="${NODE_IP:-10.68.0.39}"         # node where NodePort metrics live
METRICS_INTERVAL="${METRICS_INTERVAL:-1}" # seconds per /metrics poll
METRICS_DIR="$OUT_DIR/metrics"
DRY_RUN="${DRY_RUN:-0}"
DRY_SECONDS="${DRY_SECONDS:-5}"

mkdir -p "$OUT_DIR" "$METRICS_DIR"

# ------------------------------------------------------------ metrics capture
# Polls engine /metrics via the NodePorts (32000 decode, 32001 prefill) in the
# background while benches run. Raw dumps = post-process later, not eyeballed.
CAPTURE_PID=
start_capture() {
  echo "capture: start"
  echo "start $(date -u +%FT%TZ)" > "$METRICS_DIR/capture.log"
  (
    i=0
    while :; do
      i=$((i+1))
      ts=$(date -u +%FT%TZ)
      for pair in "30601 decode" "30600 prefill"; do
        set -- $pair
        curl -s --max-time 2 "http://$NODE_IP:$1/metrics" >> "$METRICS_DIR/${2}_metrics.raw" 2>/dev/null
        echo >> "$METRICS_DIR/${2}_metrics.raw"
      done
      if command -v nvidia-smi >/dev/null 2>&1; then
        if [ $((i % 5)) -eq 0 ]; then
          echo -n "$ts," >> "$METRICS_DIR/gpu.csv"
          nvidia-smi --query-gpu=index,utilization.gpu,memory.used,power.draw,temperature.gpu --format=csv,noheader,nounits >> "$METRICS_DIR/gpu.csv"
        fi
      fi
      echo "$ts $i" >> "$METRICS_DIR/capture.log"
      sleep "$METRICS_INTERVAL"
    done
  ) &
  CAPTURE_PID=$!
}
stop_capture() {
  if [ -n "$CAPTURE_PID" ]; then
    kill "$CAPTURE_PID" 2>/dev/null || true
    echo "capture: stopped" >> "$METRICS_DIR/capture.log"
    echo "end $(date -u +%FT%TZ)" >> "$METRICS_DIR/capture.log"
  fi
}
trap stop_capture EXIT

# /reset_prefix_cache is a dev-only route: it only exists if the server was
# started with VLLM_SERVER_DEV_MODE=1. Without it every run inherits the
# previous run's warm cache, so check up front rather than find out later.
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/reset_prefix_cache" || echo 000)
if [ "$CODE" != "200" ]; then
  echo "ERROR: POST /reset_prefix_cache returned $CODE."
  echo "  Restart the server with VLLM_SERVER_DEV_MODE=1 to enable it. Without it"
  echo "  the sweep runs with a warm prefix cache and the TTFT curve is wrong."
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: capture only, no benches ($DRY_SECONDS s)."
  start_capture
  sleep "$DRY_SECONDS"
  stop_capture
  ls -la "$METRICS_DIR"
  echo "capture samples:"
  head -c 300 "$METRICS_DIR/decode_metrics.raw" 2>/dev/null; echo
  head -c 300 "$METRICS_DIR/prefill_metrics.raw" 2>/dev/null; echo
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
    curl -s -X POST "$BASE_URL/reset_prefix_cache" > /dev/null || true
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

# ---------------------------------------------------------------- warmup
curl -s -X POST "$BASE_URL/reset_prefix_cache" > /dev/null || true
start_capture
vllm bench serve --backend openai-chat --base-url "$BASE_URL" \
  --endpoint /v1/chat/completions --model "$MODEL" --tokenizer "$TOKENIZER" \
  --dataset-name random --random-input-len 1024 --random-output-len 128 \
  --num-prompts 20 --max-concurrency 4 --ignore-eos

# ---------------------------------------------------------------- test 1: random
# Long-prompt (L-corpus) leg. --random-prefix-len 2048 = shared prefix,
# prefix cache hits. input 4096, output 1024 per canonical contract.
run random \
  --dataset-name random \
  --random-input-len 4096 \
  --random-output-len 1024 \
  --random-prefix-len 2048

# ---------------------------------------------------------------- test 2: ShareGPT
# One-time download:
#   wget https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json
run sharegpt \
  --dataset-name sharegpt \
  --dataset-path ./ShareGPT_V3_unfiltered_cleaned_split.json \
  --sharegpt-output-len 1024

echo "done — JSON results in $OUT_DIR/"
