#!/usr/bin/env bash
# Creates an external chaincode package (metadata.json + connection.json in code.tar.gz).
# Usage: ./package-cc-external.sh <cc_name> <cc_version> [connection_address]
# Example: ./package-cc-external.sh basic 1.0
# Default address: basic-cc.fabric.svc.cluster.local:9999 (must match chaincode Service in K8s)
set -e

CC_NAME="${1:-basic}"
CC_VERSION="${2:-1.0}"
# Address where the chaincode service listens (K8s Service in fabric namespace)
ADDRESS="${3:-basic-cc.fabric.svc.cluster.local:9999}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${SCRIPT_DIR}/.cc-external-$$"
trap "rm -rf ${OUT_DIR}" EXIT

mkdir -p "${OUT_DIR}/code"
echo "{\"type\":\"external\",\"label\":\"${CC_NAME}_${CC_VERSION}\"}" > "${OUT_DIR}/metadata.json"
echo "{\"address\":\"${ADDRESS}\",\"dial_timeout\":\"10s\",\"tls_required\":false}" > "${OUT_DIR}/code/connection.json"

# Package: metadata.json + code.tar.gz (contents = connection.json)
( cd "${OUT_DIR}/code" && tar czf "${OUT_DIR}/code.tar.gz" connection.json )
( cd "${OUT_DIR}" && tar czf "${SCRIPT_DIR}/${CC_NAME}_${CC_VERSION}.tar.gz" metadata.json code.tar.gz )

echo "Created ${SCRIPT_DIR}/${CC_NAME}_${CC_VERSION}.tar.gz (address=${ADDRESS})"
echo "Install with: peer lifecycle chaincode install ${CC_NAME}_${CC_VERSION}.tar.gz"
