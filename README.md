# CS5903: Distributing AI Training  - Project

## Overview

Large Language Models are widely used to generate responses repeatedly at scale. For this,
the model has to be deployed on hardware capable enough to serve requests within acceptable
latency and throughput requirements.  Prefill is largely compute-bound, while decode is more sensitive to memory bandwidth and KV-cache access. 

This project studies how infrastructure-level serving strategies affect self-hosted LLM inference. The evaluation compares plain vLLM, shared serving with llm-d and prefill-decode disaggregation with llm-d. Model parameters are kept unchanged across configurations so that the comparison focuses on serving design choices.

## Evaluation Setup

- **Model:** `coolthor/gemma-4-12B-it-FP8-dynamic`
- **Tokenizer:** `google/gemma-4-12b-it`
- **Serving:** vLLM and llm-d
- **KV-cache transfer:** NIXL for the disaggregated configuration
- **Hardware:** NVIDIA RTX A5000 and NVIDIA RTX PRO 4000 Blackwell GPUs, each with approximately 24 GB of GPU memory
- **Workloads:** Synthetic Random prompts and prompts from ShareGPT
- **Benchmarking:** `vllm bench serve` against an OpenAI-compatible endpoint

### Serving configurations

1. **Plain vLLM:** One vLLM deployment handles both prefill and decode.
2. **Shared llm-d:** Two vLLM pods handle both prefill and decode, with llm-d managing request routing.
3. **Disaggregated llm-d:** Separate prefill and decode pods handle the two stages. NIXL transfers the KV-cache state from prefill to decode.

### Workloads and metrics

The Random workload uses a fixed input length of 4096 tokens and an output length of 1024 tokens. The ShareGPT workload uses dataset-based prompts, with generation capped at 1024 tokens. The tested concurrency levels are `1, 2, 4, 8, 16, 32, 64, 128`.

The workflow includes a warm-up run and prefix-cache state resets between concurrency levels. Measurements include:

- Aggregate output throughput
- Time to first token (TTFT)
- Time per output token (TPOT)
- End-to-end request latency
- KV-cache utilization
- Scheduling metrics, including preemptions, running concurrency and waiting requests

## Repository Structure

```text
.
├── README.md
├── docs/
│   ├── Project_Report.pdf
│   ├── Architecture_Decision_Records.md
│   └── presentation.pdf
└── src/
    ├── benchmark/
    │   ├── kv_bench.sh
    │   ├── llmd_pd_bench.sh
    │   ├── llmd_plain_bench.sh
    │   ├── serve_vllm_gemma4.sh
    │   └── vllm_bench.sh
    └── setup/
        ├── admin_install.sh
        ├── gpu_config.sh
        ├── setup-llmd.sh
        └── test_gpu_pod.sh
```

### Script guide

| Script | Purpose |
|---|---|
| `src/setup/admin_install.sh` | Installs system-level dependencies required by the environment. |
| `src/setup/gpu_config.sh` | Configures GPU-related settings for the llm-d environment. |
| `src/setup/setup-llmd.sh` | Sets up the llm-d serving environment. |
| `src/setup/test_gpu_pod.sh` | Checks Kubernetes setup in GPU cluster. |
| `src/benchmark/serve_vllm_gemma4.sh` | Starts the Gemma 4 model using vLLM. |
| `src/benchmark/vllm_bench.sh` | Runs benchmarks against a vLLM endpoint. |
| `src/benchmark/llmd_plain_bench.sh` | Benchmarks the shared llm-d serving configuration. |
| `src/benchmark/llmd_pd_bench.sh` | Benchmarks the prefill-decode disaggregated llm-d configuration. |
| `src/benchmark/kv_bench.sh` | Benchmarks quantized KV-cache configuration. |

## Deliverables and Handover

- **Project report:** [`docs/Project_Report.pdf`](docs/Project_Report.pdf)
- **Architecture Decision Records:** [`docs/Architecture_Decision_Records.md`](docs/Architecture_Decision_Records.md)
- **Presentation demo:** [click here](https://drive.google.com/file/d/1p0DW053qfUWdg3pN3reTlP8fNgtLX1W5/view?usp=sharing)
