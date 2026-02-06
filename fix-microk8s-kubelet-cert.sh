#!/usr/bin/env bash
#
# Fix MicroK8s kubelet certificate so kubectl port-forward, logs, and exec work
# without "x509: cannot validate certificate ... doesn't contain any IP SANs".
#
# Run on every node (master and workers). Run with sudo so we can write
# kubelet args and restart the daemon.
#
# Usage:
#   sudo ./fix-microk8s-kubelet-cert.sh              # auto-detect this node's IP
#   sudo ./fix-microk8s-kubelet-cert.sh 192.168.2.15  # use this IP
#   sudo ./fix-microk8s-kubelet-cert.sh --full-restart # add node-ip (if needed) + full stop/start
#   sudo NODE_IP=192.168.2.15 ./fix-microk8s-kubelet-cert.sh
#
set -e

FULL_RESTART=""
if [ "${1:-}" = "--full-restart" ]; then
  FULL_RESTART=1
  shift
fi

KUBELET_ARGS="/var/snap/microk8s/current/args/kubelet"

if [ ! -d /var/snap/microk8s/current ]; then
  echo "MicroK8s not found (no /var/snap/microk8s/current). Install MicroK8s first."
  exit 1
fi

# Prefer explicit IP from arg or env
NODE_IP="${1:-${NODE_IP}}"
if [ -z "${NODE_IP}" ]; then
  # Default route interface's primary address
  NODE_IP=$(ip -o route get 1 2>/dev/null | sed -n 's/.*src \(\S*\).*/\1/p')
fi
if [ -z "${NODE_IP}" ]; then
  NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
if [ -z "${NODE_IP}" ]; then
  echo "Could not detect this node's IP. Pass it as an argument or set NODE_IP:"
  echo "  sudo ./fix-microk8s-kubelet-cert.sh 192.168.2.15"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo so we can write ${KUBELET_ARGS} and restart the daemon:"
  echo "  sudo $0 ${NODE_IP}"
  exit 1
fi

if ! grep -q '\-\-node-ip=' "${KUBELET_ARGS}" 2>/dev/null; then
  echo "Adding --node-ip=${NODE_IP} to ${KUBELET_ARGS}"
  echo "--node-ip=${NODE_IP}" >> "${KUBELET_ARGS}"
else
  echo "Kubelet already has --node-ip in ${KUBELET_ARGS}."
  grep '\-\-node-ip=' "${KUBELET_ARGS}" || true
fi

if [ -n "${FULL_RESTART}" ]; then
  echo "Performing full MicroK8s stop (all services will go down on this node)..."
  microk8s stop
  echo "Starting MicroK8s..."
  microk8s start
  echo "Done. Full stop/start complete. Wait for the node to be Ready, then try port-forward again."
else
  echo "Restarting MicroK8s kubelite..."
  snap restart microk8s.daemon-kubelite
  echo "Done. The kubelet will use node IP ${NODE_IP}; its serving cert may be re-issued with this IP in SANs."
  echo "Wait a few seconds, then try: kubectl -n fabric port-forward svc/orderer-example-com 7050:7050 &"
  echo "If the x509 error persists, run with --full-restart on each node: sudo $0 --full-restart"
fi
