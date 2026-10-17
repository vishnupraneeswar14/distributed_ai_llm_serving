#!/usr/bin/env bash
# Run a concurrency sweep against the plain vLLM server.
# This uses one engine and one metrics port, unlike the PD-disaggregated setup.
# Run this where $BASE_URL is reachable. It defaults to localhost.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
MODEL="${MODEL:-gemma4-12b}"                                # --served-model-name on the server
TOKENIZER="${TOKENIZER:-coolthor/gemma-4-12B-it-FP8-dynamic}"             
OUT_DIR="${OUT_DIR:-gemma-4_12B_kv_cache}"
#LEVELS="4 8 64"
#LEVELS="128"
LEVELS="1 2 4 8 16 32 64 128"
METRICS_INTERVAL="${METRICS_INTERVAL:-1}"
METRICS_DIR="$OUT_DIR/metrics"
DRY_RUN="${DRY_RUN:-0}"
DRY_SECONDS="${DRY_SECONDS:-5}"

mkdir -p "$OUT_DIR" "$METRICS_DIR"

# Metrics capture
# Poll the plain server's /metrics endpoint in the background while benchmarks run.
# Raw metrics are saved for processing later.
_MH=${BASE_URL#http://}
_MH=${_MH%%:*}
CAPTURE_METRICS_HOST="${METRICS_HOST:-$_MH}"
# Metrics use the server's port, not a separate NodePort.
if [[ "$BASE_URL" =~ :([0-9]+)$ ]]; then _MP=${BASH_REMATCH[1]}; else _MP=80; fi
CAPTURE_METRICS_PORT="${METRICS_PORT:-$_MP}"

CAPTURE_PID=
CAPTURE_RAW=
CAPTURE_LOG=
start_capture() {  # start_capture <tag>, e.g. random or sharegpt
  local tag="$1"
  CAPTURE_RAW="$METRICS_DIR/${tag}.raw"
  CAPTURE_LOG="$METRICS_DIR/capture.${tag}.log"
  : > "$CAPTURE_RAW"
  echo "capture: start http://$CAPTURE_METRICS_HOST:$CAPTURE_METRICS_PORT"
  echo "capture: raw=$CAPTURE_RAW log=$CAPTURE_LOG"
  echo "start $(date -u +%FT%TZ)" > "$CAPTURE_LOG"
  (
    i=0
    while :; do
      i=$((i+1))
      ts=$(date -u +%FT%TZ)
      curl -s --max-time 2 "http://$CAPTURE_METRICS_HOST:$CAPTURE_METRICS_PORT/metrics" >> "$CAPTURE_RAW" 2>/dev/null
      echo >> "$CAPTURE_RAW"
      if command -v nvidia-smi >/dev/null 2>&1; then
        if [ $((i % 5)) -eq 0 ]; then
          echo -n "$ts," >> "$METRICS_DIR/gpu.csv"
          nvidia-smi --query-gpu=index,utilization.gpu,memory.used,power.draw,temperature.gpu --format=csv,noheader,nounits >> "$METRICS_DIR/gpu.csv"
        fi
      fi
      echo "$ts $i" >> "$CAPTURE_LOG"
      sleep "$METRICS_INTERVAL"
    done
  ) &
  CAPTURE_PID=$!
}
stop_capture() {
  if [ -n "$CAPTURE_PID" ]; then
    kill "$CAPTURE_PID" 2>/dev/null || true
    wait "$CAPTURE_PID" 2>/dev/null || true
    echo "capture: stopped" >> "$CAPTURE_LOG"
    echo "end $(date -u +%FT%TZ)" >> "$CAPTURE_LOG"
    CAPTURE_PID=
  fi
}
trap stop_capture EXIT

# The prefix-cache reset route requires VLLM_SERVER_DEV_MODE=1 on the server.
# Without it, each run may start with a warm prefix cache.
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/reset_prefix_cache" || echo 000)
if [ "$CODE" != "200" ]; then
  echo "ERROR: POST /reset_prefix_cache returned $CODE."
  echo "  Start server with VLLM_SERVER_DEV_MODE=1 (serve.sh exports it)."
  exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN: capture only, no benches ($DRY_SECONDS s)."
  start_capture random
  sleep "$DRY_SECONDS"
  stop_capture
  ls -la "$METRICS_DIR"
  echo "capture samples:"
  head -c 300 "$METRICS_DIR/random.raw" 2>/dev/null; echo
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

# Warmup
curl -s -X POST "$BASE_URL/reset_prefix_cache" > /dev/null || true
vllm bench serve --backend openai-chat --base-url "$BASE_URL" \
  --endpoint /v1/chat/completions --model "$MODEL" --tokenizer "$TOKENIZER" \
  --dataset-name random --random-input-len 1024 --random-output-len 128 \
  --num-prompts 20 --max-concurrency 4 --ignore-eos

# Random workload
# Use 4096 input tokens and 1024 output tokens for this workload.
start_capture random
run random \
  --dataset-name random \
  --random-input-len 4096 \
  --random-output-len 1024 \
  --random-prefix-len 2048
stop_capture

# ShareGPT workload
# Download this dataset once if it is not already present:
# wget https://huggingface.co/datasets/anon8231489123/ShareGPT_Vicuna_unfiltered/resolve/main/ShareGPT_V3_unfiltered_cleaned_split.json
start_capture sharegpt
run sharegpt \
  --dataset-name sharegpt \
  --dataset-path ./ShareGPT_V3_unfiltered_cleaned_split.json \
  --sharegpt-output-len 1024
stop_capture

echo "Done. JSON results are in $OUT_DIR/."
