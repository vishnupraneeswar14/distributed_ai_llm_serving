# Architecture Decision Records (ADRs)

## ADR-001: Serving Framework Selection

**Context:** The project evaluates infrastructure-level strategies for serving self-hosted LLMs. vLLM and llm-d are used to compare different serving configurations.



**Options considered:**

- Plain vLLM
- llm-d

**Decision:** Use vLLM as the model-serving engine and llm-d for workload-aware load balancing with the vLLM engine.

## ADR-002: Request Routing and Serving Endpoint

**Context:** The benchmark client requires an endpoint to submit inference requests. The endpoint and request path depend on the serving configuration being evaluated.



**Options considered:**

- Direct access to the vLLM endpoint
- Access through the llm-d serving infrastructure

**Decision:** Use the OpenAI-compatible endpoint provided by each vLLM pod in the llm-d setup to submit benchmark requests.

## ADR-003: Model Selection and Precision

**Context:** The project requires a common model to compare serving configurations without changing model parameters across experiments. The model must also fit the available GPUs, which have approximately 24 GB of VRAM each.



**Options considered:**

- Gemma 4 12B with FP8 weights
- Llama 3.1 8B with BF16/FP16 weights
- Mistral 7B with BF16/FP16 weights
- Qwen2.5 14B with mixed-precision weights

**Decision:** Use `coolthor/gemma-4-12B-it-FP8-dynamic` with the `google/gemma-4-12b-it` tokenizer, as Gemma 4 is relatively newer and the FP8 checkpoint allows more VRAM to be allocated to the KV cache within the available 24 GB GPU memory constraint.

## ADR-004: Benchmarking Methodology

**Context:** Comparing serving configurations requires consistent workloads, concurrency levels, and performance metrics. The evaluation uses controlled synthetic requests and dataset-based prompts.



**Options considered:**

- **Benchmark tool:** `vllm bench serve`
- **Workloads:** Random and ShareGPT datasets
- **Random workload lengths:** Fixed input length of 4096 tokens and output length of 1024 tokens, or variable input and output lengths
- **ShareGPT output length:** Cap output at 1024 tokens or use uncapped generation
- **Concurrency:** Test levels of 1, 2, 4, 8, 16, 32, 64, and 128
- **Metrics:** Throughput, TTFT, TPOT, end-to-end latency, KV-cache utilization, and scheduling metrics
- **Measurement source:** Collect benchmark-client and serving-engine (vLLM) metrics or rely only on client-side measurements
- **Warm-up:** Perform a warm-up run before measurement or measure immediately
- **Prefix-cache handling:** Reset prefix-cache state between concurrency levels or retain the cache state

**Decision:** Use `vllm bench serve` with Random and ShareGPT workloads, above specified concurrency levels and workload lengths, a warm-up run, prefix-cache resets between concurrency levels and consistent collection of client-side and engine-level metrics.

## ADR-005: Endpoint Exposure

**Context:** The benchmark client must access the serving deployment through a reachable endpoint.



**Options considered:**

- Direct access to the vLLM endpoint
- Kubernetes NodePort for endpoint exposure

**Decision:** Use NodePort to expose the serving endpoint as it has less setup overhead in llm-d.

## ADR-006: KV-Cache Transfer

**Context:** In disaggregated serving, the KV-cache state generated during prefill must be transferred to the decode stage. This introduces communication overhead that can affect overall serving performance.



**Options considered:**

- NIXL
- Mooncake Transfer Engine

**Decision:** Use NIXL to transfer KV-cache state because it is integrated with the llm-d disaggregated serving stack and provides an efficient KV-cache transfer interface that supports multiple communication backends.
