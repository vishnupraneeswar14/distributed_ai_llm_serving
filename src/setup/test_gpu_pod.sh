#!/usr/bin/env bash
# ============================================================================
# Check that a pod in k3s can request a GPU and run nvidia-smi.
# Run as root: sudo bash test-gpu-pod.sh
# The pod logs should show the GPU model.
# ============================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root"; exit 1; }
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "==> deploy gputest pod (requests 1 GPU, runs nvidia-smi)"
kubectl delete pod gputest --ignore-not-found --wait=true >/dev/null 2>&1 || true

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gputest
spec:
  restartPolicy: Never
  containers:
  - name: gputest
    image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: "1"
EOF

echo "==> waiting for pod to run (image pull may take time)..."
kubectl wait --for=condition=Ready pod/gputest --timeout=300s || kubectl describe pod gputest | tail -20

echo "==> logs:"
kubectl logs gputest

echo "==> cleanup"
kubectl delete pod gputest --wait=true >/dev/null 2>&1 || true
echo "  done. If logs showed 'NVIDIA RTX ...' -> GPU-in-k3s WORKS."
