#!/usr/bin/env bash
# Set up the GPU node. Run with: sudo bash admin_install.sh
# Existing components are left alone where possible.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root (sudo)"; exit 1; }

apt_missing() { dpkg -s "$1" >/dev/null 2>&1 && return 1 || return 0; }

# Base packages
echo "==> Checking base packages (containerd, uidmap, slirp4netns)"
NEED=""
for p in containerd uidmap slirp4netns; do apt_missing "$p" && NEED="$NEED $p"; done
if [ -n "$NEED" ]; then
  apt-get update -y
  apt-get install -y $NEED
else
  echo "  Already installed, skipping"
fi

# NVIDIA container support
echo "==> Checking NVIDIA Container Toolkit"
if apt_missing nvidia-container-toolkit; then
  apt-get update -y
  apt-get install -y nvidia-container-toolkit
else
  echo "  Already installed, skipping"
fi

# Make sure containerd knows about the NVIDIA runtime
echo "==> Checking NVIDIA runtime in containerd"
if [ -f /etc/containerd/config.toml ] && grep -q nvidia /etc/containerd/config.toml 2>/dev/null; then
  echo "  NVIDIA runtime already appears in the config, skipping"
else
  {
    until nvidia-ctk runtime configure --runtime=containerd --config=/etc/containerd/config.toml; do echo "  nvidia-ctk failed, trying again in 2 seconds..."; sleep 2; done
  }
  systemctl restart containerd || true
  echo "  NVIDIA runtime configured; containerd restarted"
fi

# Start k3s if it is not already running
echo "==> Checking k3s"
if systemctl is-active --quiet k3s.service 2>/dev/null; then
  echo "  k3s is already running, skipping"
else
  curl -sfL https://get.k3s.io | sh -
fi
echo "  Node join token: $(cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || echo 'unavailable')"

# Let workloads run on the control-plane node too
echo "==> Making the control-plane node available for workloads"
if k3s kubectl get nodes 2>/dev/null | grep -q control-plane; then
  k3s kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || echo "  No taint to remove; the node may already accept workloads"
else
  echo "  No control-plane node found, skipping"
fi

# Install kubectl and Helm if needed
echo "==> Checking kubectl and Helm"
if command -v kubectl >/dev/null 2>&1; then
  echo "  kubectl is already installed ($(kubectl version --client 2>/dev/null | head -1))"
else
  apt-get install -y --no-install-recommends ca-certificates curl gnupg
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -y
  apt-get install -y kubectl
  echo "  kubectl installed"
fi
if command -v helm >/dev/null 2>&1; then
  echo "  Helm is already installed ($(helm version --short 2>/dev/null))"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  echo "  Helm installed"
fi

echo ""
echo "==> Quick check of what is installed:"
nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | sed 's/^/  driver: /'
nvidia-ctk --version 2>/dev/null | head -1 | sed 's/^/  toolkit: /'
grep -q nvidia /etc/containerd/config.toml 2>/dev/null && echo "  containerd: NVIDIA runtime found in config" || echo "  containerd: NVIDIA runtime not found in config"
k3s --version 2>/dev/null | head -1 | sed 's/^/  k3s: /'
k3s kubectl get nodes 2>/dev/null | sed 's/^/  node: /'
kubectl version --client 2>/dev/null | head -1 | sed 's/^/  kubectl: /'
helm version --short 2>/dev/null | sed 's/^/  helm: /'
