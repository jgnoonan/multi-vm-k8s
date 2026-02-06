#!/usr/bin/env bash
#
# Generate test-network crypto material and genesis block without Docker.
# Use this if "./network.sh up" does not create system-genesis-block or organizations/
# (e.g. Docker not available or network.sh fails). Requires Fabric binaries in
# fabric-samples/bin (run install-fabric.sh binary from parent of fabric-samples).
#
# Run from multi-vm-k8s (or set TEST_NETWORK_PATH). Then run create-fabric-secrets.sh.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NETWORK_PATH="${TEST_NETWORK_PATH:-${SCRIPT_DIR}/../test-network}"
BIN_PATH="${TEST_NETWORK_PATH}/../bin"

if [ ! -d "${TEST_NETWORK_PATH}/organizations/cryptogen" ]; then
  echo "test-network not found at ${TEST_NETWORK_PATH}. Set TEST_NETWORK_PATH if needed."
  echo "You need the full fabric-samples repo (including test-network); the multi-vm-k8s zip alone is not enough."
  exit 1
fi

CONFIGTX_YAML="${TEST_NETWORK_PATH}/configtx/configtx.yaml"
mkdir -p "${TEST_NETWORK_PATH}/configtx"

# Genesis block must be a system channel block (TwoOrgsOrdererGenesis) with ConsortiumsConfig.
# ChannelUsingRaft produces a different format that orderer rejects as "lacks ConsortiumsConfig".
# Configtx lives in test-network/configtx; we use or create it there.
ensure_configtx() {
  if [ -f "${CONFIGTX_YAML}" ] && grep -q "TwoOrgsOrdererGenesis" "${CONFIGTX_YAML}" 2>/dev/null; then
    return 0
  fi
  echo "Writing configtx with TwoOrgsOrdererGenesis to test-network: ${CONFIGTX_YAML}"
  write_default_configtx
}

write_default_configtx() {
  cat > "${CONFIGTX_YAML}" << 'CONFIGTX_EOF'
---
# Default configtx for multi-vm-k8s (TwoOrgsOrdererGenesis + TwoOrgsChannel)
Organizations:
    - &OrdererOrg
        Name: OrdererOrg
        ID: OrdererMSP
        MSPDir: ../organizations/ordererOrganizations/example.com/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('OrdererMSP.member')"
            Writers:
                Type: Signature
                Rule: "OR('OrdererMSP.member')"
            Admins:
                Type: Signature
                Rule: "OR('OrdererMSP.admin')"
        OrdererEndpoints:
            - orderer.example.com:7050
    - &Org1
        Name: Org1MSP
        ID: Org1MSP
        MSPDir: ../organizations/peerOrganizations/org1.example.com/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('Org1MSP.admin', 'Org1MSP.peer', 'Org1MSP.client')"
            Writers:
                Type: Signature
                Rule: "OR('Org1MSP.admin', 'Org1MSP.client')"
            Admins:
                Type: Signature
                Rule: "OR('Org1MSP.admin')"
            Endorsement:
                Type: Signature
                Rule: "OR('Org1MSP.peer')"
    - &Org2
        Name: Org2MSP
        ID: Org2MSP
        MSPDir: ../organizations/peerOrganizations/org2.example.com/msp
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('Org2MSP.admin', 'Org2MSP.peer', 'Org2MSP.client')"
            Writers:
                Type: Signature
                Rule: "OR('Org2MSP.admin', 'Org2MSP.client')"
            Admins:
                Type: Signature
                Rule: "OR('Org2MSP.admin')"
            Endorsement:
                Type: Signature
                Rule: "OR('Org2MSP.peer')"
Capabilities:
    Channel: &ChannelCapabilities
        V2_0: true
    Orderer: &OrdererCapabilities
        V2_0: true
    Application: &ApplicationCapabilities
        V2_0: true
Application: &ApplicationDefaults
    Organizations:
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
        LifecycleEndorsement:
            Type: ImplicitMeta
            Rule: "MAJORITY Endorsement"
        Endorsement:
            Type: ImplicitMeta
            Rule: "MAJORITY Endorsement"
    Capabilities:
        <<: *ApplicationCapabilities
Orderer: &OrdererDefaults
    OrdererType: etcdraft
    Addresses:
        - orderer.example.com:7050
    EtcdRaft:
        Consenters:
        - Host: orderer.example.com
          Port: 7050
          ClientTLSCert: ../organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt
          ServerTLSCert: ../organizations/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt
    BatchTimeout: 2s
    BatchSize:
        MaxMessageCount: 10
        AbsoluteMaxBytes: 99 MB
        PreferredMaxBytes: 512 KB
    Organizations:
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
        BlockValidation:
            Type: ImplicitMeta
            Rule: "ANY Writers"
Channel: &ChannelDefaults
    Policies:
        Readers:
            Type: ImplicitMeta
            Rule: "ANY Readers"
        Writers:
            Type: ImplicitMeta
            Rule: "ANY Writers"
        Admins:
            Type: ImplicitMeta
            Rule: "MAJORITY Admins"
    Capabilities:
        <<: *ChannelCapabilities
Profiles:
    TwoOrgsOrdererGenesis:
        <<: *ChannelDefaults
        Orderer:
            <<: *OrdererDefaults
            Organizations:
                - *OrdererOrg
            Capabilities:
                <<: *OrdererCapabilities
        Consortiums:
            SampleConsortium:
                Organizations:
                    - *Org1
                    - *Org2
    TwoOrgsChannel:
        Consortium: SampleConsortium
        <<: *ChannelDefaults
        Application:
            <<: *ApplicationDefaults
            Organizations:
                - *Org1
                - *Org2
            Capabilities:
                <<: *ApplicationCapabilities
CONFIGTX_EOF
}

if ensure_configtx; then
  echo "Using configtx with TwoOrgsOrdererGenesis for genesis block (system channel with ConsortiumsConfig)."
  GENESIS_PROFILE="TwoOrgsOrdererGenesis"
  GENESIS_CONFIG_PATH="${TEST_NETWORK_PATH}/configtx"
else
  echo "Orderer requires a system channel genesis block (TwoOrgsOrdererGenesis with ConsortiumsConfig)."
  echo "Could not create or find valid configtx at ${CONFIGTX_YAML}"
  exit 1
fi

if [ ! -f "${BIN_PATH}/configtxgen" ] || [ ! -f "${BIN_PATH}/cryptogen" ]; then
  echo "Fabric binaries not found in ${BIN_PATH}."
  echo "From the parent of fabric-samples run: ./install-fabric.sh binary"
  exit 1
fi

export PATH="${BIN_PATH}:$PATH"

cd "${TEST_NETWORK_PATH}"
mkdir -p system-genesis-block

# Some Fabric peer CLI builds expect TLS server name peer0.org1.com / peer0.org2.com.
# Add these to peer TLS cert SANS so the CLI accepts the connection.
ORG1_CRYPTO="${TEST_NETWORK_PATH}/organizations/cryptogen/crypto-config-org1.yaml"
ORG2_CRYPTO="${TEST_NETWORK_PATH}/organizations/cryptogen/crypto-config-org2.yaml"
for f in "$ORG1_CRYPTO" "$ORG2_CRYPTO"; do
  [ -f "$f" ] || continue
  if echo "$f" | grep -q org1; then
    grep -q "peer0.org1.com" "$f" 2>/dev/null || sed -i.bak '/- localhost$/a\        - peer0.org1.com' "$f"
  else
    grep -q "peer0.org2.com" "$f" 2>/dev/null || sed -i.bak '/- localhost$/a\        - peer0.org2.com' "$f"
  fi
done

echo "Generating Org1 identities (cryptogen)..."
cryptogen generate --config=./organizations/cryptogen/crypto-config-org1.yaml --output="organizations"

echo "Generating Org2 identities (cryptogen)..."
cryptogen generate --config=./organizations/cryptogen/crypto-config-org2.yaml --output="organizations"

echo "Generating Orderer identities (cryptogen)..."
cryptogen generate --config=./organizations/cryptogen/crypto-config-orderer.yaml --output="organizations"

echo "Generating orderer genesis block (configtxgen with system channel profile)..."
configtxgen -configPath "${GENESIS_CONFIG_PATH}" -profile "${GENESIS_PROFILE}" -channelID system-channel -outputBlock ./system-genesis-block/genesis.block

if [ -f "./organizations/ccp-generate.sh" ]; then
  echo "Generating CCP files..."
  chmod +x ./organizations/ccp-generate.sh
  ./organizations/ccp-generate.sh
fi

echo "Done. Verify with:"
echo "  ls ${TEST_NETWORK_PATH}/system-genesis-block/genesis.block"
echo "  ls ${TEST_NETWORK_PATH}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp"
echo "Then run: ./create-fabric-secrets.sh"
