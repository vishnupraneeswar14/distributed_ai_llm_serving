#!/usr/bin/env bash
# ============================================================================
# Set up llm-d on the k3s cluster.
# Based on the llm-d release-0.7 quickstart:
#   - Gateway API Inference Extension CRDs, v1.5.0
#   - Standalone router chart with Envoy
#   - vLLM model server setup for one host
#
# Run as root: sudo bash setup-llmd.sh
# Run the cluster and GPU setup first.
# This script installs Helm and jq if they are missing.
#
# Change these settings to fit your node.
#   MODEL: model to run. Qwen3-0.6B is a small model.
#   REPLICAS: number of model server replicas.
#   GPUS_PER_REPLICA: number of GPUs for each replica.
# The GPUs on this node are different (A5000 and RTX PRO 4000), so TP=1 is needed.
# Tensor parallel needs matching GPUs, so these two cannot be mixed.
# ============================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root"; exit 1; }
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
KUBECONF="$KUBECONFIG"
KC="kubectl"

# ----------------------------- SETTINGS --------------------------------------
GAIE_VERSION="${GAIE_VERSION:-v1.5.0}"
NAMESPACE="${NAMESPACE:-llm-d-quickstart}"
GUIDE_NAME="${GUIDE_NAME:-quickstart}"
MODEL="${MODEL:-Qwen/Qwen3-0.6B}"
REPLICAS="${REPLICAS:-1}"
GPUS_PER_REPLICA="${GPUS_PER_REPLICA:-1}"
# Keep tensor-parallel-size in sync with GPUS_PER_REPLICA.
TP_SIZE="${TP_SIZE:-$GPUS_PER_REPLICA}"
REPO_DIR="${REPO_DIR:-/opt/llm-d}"
# ----------------------------------------------------------------------------


kubectl(){ KUBECONFIG=$KUBECONF /usr/local/bin/k3s kubectl "$@"; }
step(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

command -v jq  >/dev/null 2>&1 || { step "install jq"; apt-get install -y jq  >/dev/null 2>&1; }
command -v helm >/dev/null 2>&1 || { step "install helm"; curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null 2>&1; }

step "Getting the llm-d repo"
[ -d "$REPO_DIR" ] && rm -rf "$REPO_DIR"
git clone --branch release-0.7 --depth 1 https://github.com/llm-d/llm-d.git "$REPO_DIR"

step "Installing the Gateway API Inference Extension CRDs"
kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GAIE_VERSION}"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

step "Deploying the llm-d router"
helm upgrade -i "$GUIDE_NAME" \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/standalone \
  -f "$REPO_DIR/guides/recipes/scheduler/base.values.yaml" \
  -f "$REPO_DIR/guides/optimized-baseline/scheduler/optimized-baseline.values.yaml" \
  -n "$NAMESPACE" --version "$GAIE_VERSION"

step "Adjusting model server settings for $MODEL ($REPLICAS replicas, $GPUS_PER_REPLICA GPU each)"
PATCH="$REPO_DIR/guides/optimized-baseline/modelserver/gpu/vllm/base/patch-vllm.yaml"
sed -i \
  -e "s|^  replicas: 8|  replicas: $REPLICAS|" \
  -e "s|- \"Qwen/Qwen3-32B\"|- \"$MODEL\"|" \
  -e "s|--tensor-parallel-size=2|--tensor-parallel-size=$TP_SIZE|" \
  -e "s|nvidia.com/gpu: 2|nvidia.com/gpu: $GPUS_PER_REPLICA|g" \
  -e "s|memory: 128Gi|memory: 24Gi|" \
  -e "s|memory: 96Gi|memory: 16Gi|" \
  -e "s|cpu: '16'|cpu: '8'|" \
  -e "s|cpu: '8'|cpu: '4'|" \
  "$PATCH"
echo "  patched: $PATCH"
grep -E "replicas:|Qwen|tensor-parallel-size|nvidia.com/gpu" "$PATCH" || true


step "Deploying the model server"
kubectl apply -n "$NAMESPACE" -k "$REPO_DIR/guides/optimized-baseline/modelserver/gpu/vllm/base/"

echo ""
echo "  ================================================================"
echo "  NEXT (run when you're ready, not in this script):"
echo "    watch pods:   kubectl -n $NAMESPACE get pods -w"
echo "    find proxy:   kubectl -n $NAMESPACE get svc"
echo "    port-forward: kubectl -n $NAMESPACE port-forward svc/<PROXY_SVC> 8080:80"
echo "    test:  curl -X POST localhost:8080/v1/completions \\"
echo "             -H 'Content-Type: application/json' \\"
echo "             -d '{\"model\":\"$MODEL\",\"prompt\":\"hi\",\"max_tokens\":20}'"
echo "  ================================================================"
