#!/bin/bash
# Start Gemma 4 12B-it FP8 with vLLM.
#
# Run with the default settings:
# Set PORT or another variable to override a default.
#
# TRITON_ATTN is required for Gemma 4 because its attention head dimensions differ.
# Other attention backends may not handle this correctly.
# Using the wrong backend can cause bad output or a crash.

set -euo pipefail
cd "$(dirname "$0")"

MODEL="${MODEL:-coolthor/gemma-4-12B-it-FP8-dynamic}"
PORT="${PORT:-8000}"
MAX_LEN="${MAX_LEN:-131072}"
GPU_UTIL="${GPU_UTIL:-0.90}"

if [ ! -f .venv/bin/activate ]; then
  echo "error: no .venv in $(pwd)" >&2
  exit 1
fi
source .venv/bin/activate

export VLLM_ATTENTION_BACKEND=TRITON_ATTN
#export CUDA_HOME=/home/devansh/.venv/lib/python3.13/site-packages/nvidia/cu13
#export PATH=$CUDA_HOME/bin:$PATH
export VLLM_USE_FLASHINFER_SAMPLER=0
export VLLM_SERVER_DEV_MODE=1    # exposes /reset_prefix_cache for the bench sweeps
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export HF_HUB_ENABLE_HF_TRANSFER=1

echo "Python: $(which python)"
echo "vLLM: $(python -c 'import vllm; print(vllm.__version__)' 2>/dev/null || echo NOT-INSTALLED)"
echo "Model: $MODEL"
echo "Port: $PORT, max model length: $MAX_LEN, GPU utilization: $GPU_UTIL"
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv
echo

vllm serve "$MODEL" \
  --served-model-name gemma4-12b \
  --max-model-len "$MAX_LEN" \
  --gpu-memory-utilization "$GPU_UTIL" \
  --host 0.0.0.0 \
  --port "$PORT" \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --enable-auto-tool-choice \
  --tool-call-parser gemma4 \
  --reasoning-parser gemma4 \
  --trust-remote-code
