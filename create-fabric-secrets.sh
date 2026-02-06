#!/usr/bin/env bash
#
# Copyright IBM Corp. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Creates Kubernetes secrets from test-network crypto material and genesis block.
# Run from fabric-samples/test-network: ./network.sh up
# Then run this script from multi-vm-k8s (or set TEST_NETWORK_PATH, e.g. /home/djahid/fabric-samples/test-network).
#
# For MicroK8s, the script uses "microk8s kubectl" if "kubectl" is not in PATH.
# Override with: KUBECTL=kubectl or KUBECTL="microk8s kubectl"
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NETWORK_PATH="${TEST_NETWORK_PATH:-${SCRIPT_DIR}/../test-network}"
FABRIC_NS="${FABRIC_NS:-fabric}"

# Use microk8s kubectl when kubectl is not available (e.g. MicroK8s)
if [ -z "${KUBECTL}" ]; then
  if command -v kubectl >/dev/null 2>&1; then
    KUBECTL=kubectl
  elif command -v microk8s >/dev/null 2>&1 && microk8s kubectl version --client >/dev/null 2>&1; then
    KUBECTL="microk8s kubectl"
  else
    echo "kubectl not found. Install kubectl or MicroK8s, or set KUBECTL (e.g. KUBECTL='microk8s kubectl')."
    exit 1
  fi
fi
echo "Using: ${KUBECTL}"

if [ ! -f "${TEST_NETWORK_PATH}/system-genesis-block/genesis.block" ]; then
  echo "Genesis block not found. Generate crypto first:"
  echo "  cd ${TEST_NETWORK_PATH} && ./network.sh up"
  echo ""
  echo "Do not run './network.sh down' before running this script—down removes the crypto and genesis block."
  echo "Run: network.sh up -> create-fabric-secrets.sh -> then you may run network.sh down if desired."
  exit 1
fi

echo "Using test-network at: ${TEST_NETWORK_PATH}"
echo "Namespace: ${FABRIC_NS}"

${KUBECTL} create namespace "${FABRIC_NS}" --dry-run=client -o yaml | ${KUBECTL} apply -f -

# Orderer genesis block (single key genesis.block)
${KUBECTL} create secret generic orderer-genesis-block \
  --from-file=genesis.block="${TEST_NETWORK_PATH}/system-genesis-block/genesis.block" \
  -n "${FABRIC_NS}" \
  --dry-run=client -o yaml | ${KUBECTL} apply -f -

# Create tarballs so directory structure is preserved in secrets (K8s secret keys are flat)
ORDERER_BASE="${TEST_NETWORK_PATH}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com"
TMPDIR="${TMPDIR:-/tmp}/fabric-k8s-secrets-$$"
mkdir -p "${TMPDIR}"
trap "rm -rf ${TMPDIR}" EXIT

( cd "${ORDERER_BASE}" && tar -czf "${TMPDIR}/orderer-msp.tar.gz" msp )
( cd "${ORDERER_BASE}" && tar -czf "${TMPDIR}/orderer-tls.tar.gz" tls )
${KUBECTL} create secret generic orderer-msp --from-file=msp.tar.gz="${TMPDIR}/orderer-msp.tar.gz" -n "${FABRIC_NS}" --dry-run=client -o yaml | ${KUBECTL} apply -f -
${KUBECTL} create secret generic orderer-tls --from-file=tls.tar.gz="${TMPDIR}/orderer-tls.tar.gz" -n "${FABRIC_NS}" --dry-run=client -o yaml | ${KUBECTL} apply -f -

# Peer0 Org1
ORG1_BASE="${TEST_NETWORK_PATH}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com"
( cd "${ORG1_BASE}" && tar -czf "${TMPDIR}/peer0-org1-msp.tar.gz" msp )
( cd "${ORG1_BASE}" && tar -czf "${TMPDIR}/peer0-org1-tls.tar.gz" tls )
${KUBECTL} create secret generic peer0-org1-msp --from-file=msp.tar.gz="${TMPDIR}/peer0-org1-msp.tar.gz" -n "${FABRIC_NS}" --dry-run=client -o yaml | ${KUBECTL} apply -f -
${KUBECTL} create secret generic peer0-org1-tls --from-file=tls.tar.gz="${TMPDIR}/peer0-org1-tls.tar.gz" -n "${FABRIC_NS}" --dry-run=client -o yaml | ${KUBECTL} apply -f -

# Peer0 Org2
ORG2_BASE="${TEST_NETWORK_PATH}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com"
( cd "${ORG2_BASE}" && tar -czf "${TMPDIR}/peer0-org2-msp.tar.gz" msp )
( cd "${ORG2_BASE}" && tar -czf "${TMPDIR}/peer0-org2-tls.tar.gz" tls )
${KUBECTL} create secret generic peer0-org2-msp --from-file=msp.tar.gz="${TMPDIR}/peer0-org2-msp.tar.gz" -n "${FABRIC_NS}" --dry-run=client -o yaml | ${KUBECTL} apply -f -
${KUBECTL} create secret generic peer0-org2-tls --from-file=tls.tar.gz="${TMPDIR}/peer0-org2-tls.tar.gz" -n "${FABRIC_NS}" --dry-run=client -o yaml | ${KUBECTL} apply -f -

echo "Secrets created in namespace ${FABRIC_NS}. Deploy with: ${KUBECTL} apply -f . -n ${FABRIC_NS}"
echo "Placement: orderer→worker2, peer0-org1→master, peer0-org2→worker1"
