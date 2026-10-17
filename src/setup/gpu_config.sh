#!/usr/bin/env bash
# ============================================================================
# Set up NVIDIA GPU support in k3s and check that it works.
# Run this on the k3s node as root: sudo bash k3s-gpu-config.sh
#

# k3s uses its own containerd config, so the NVIDIA runtime must be set up there.
# Its config is at /var/lib/rancher/k3s/agent/etc/containerd.
# It ignores /etc/containerd/config.toml, so the system containerd check can be misleading.
# ============================================================================
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)"; exit 1; }

KUBECONF=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG=$KUBECONF

echo "==> Checking NVIDIA toolkit and GPUs"
nvidia-ctk cdi list 2>/dev/null | head -3 || echo "  (no CDI devices; nvidia runtime path used instead)"
nvidia-smi --query-gpu=name --format=csv,noheader | head -3

echo "==> Setting the NVIDIA runtime for k3s"
# official k3s approach: config.yaml 'default-runtime: nvidia'
mkdir -p /etc/rancher/k3s
if grep -q default-runtime /etc/rancher/k3s/config.yaml 2>/dev/null; then
  echo "  SKIP: default-runtime already set"
else
  echo "default-runtime: nvidia" >> /etc/rancher/k3s/config.yaml
  echo "  added default-runtime: nvidia to /etc/rancher/k3s/config.yaml"
fi
systemctl restart k3s
sleep 10
echo "  k3s restarted. nvidia runtime in k3s containerd:"
grep -i nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml 2>/dev/null | head -3 \
  || echo "  (nvidia runtime not in k3s containerd config - check k3s version supports it)"

echo "==> Installing the NVIDIA device plugin"
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin 2>/dev/null || true
helm repo update nvdp >/dev/null
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.17.1
echo "  device plugin deployed"

echo "==> Checking which GPUs the node reports"
kubectl wait --for=condition=Available -n nvidia-device-plugin deploy/nvdp-nvidia-device-plugin --timeout=120s 2>/dev/null || true
sleep 10
echo "  plugin pods:"
kubectl get pods -n nvidia-device-plugin
echo "  node allocatable GPUs:"
kubectl get node "$(hostname | tr 'A-Z' 'a-z')" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null \
  || kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}: {.status.allocatable.nvidia\.com/gpu}{"\n"}{end}'
echo "  (looking for nvidia.com/gpu: <N>)"
