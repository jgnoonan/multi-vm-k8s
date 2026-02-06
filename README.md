# Hyperledger Fabric on Kubernetes (multi-node)

Deploy a minimal Fabric network (orderer + 2 peers) on Kubernetes with fixed node placement. Chaincode runs as an external service (no Docker in peer pods).

**Paths in this guide use `/home/djahid`.** If your home directory is different, replace it. We assume:
- `fabric-samples` is at `/home/djahid/fabric-samples`
- This directory (`multi-vm-k8s`) is at `/home/djahid/fabric-samples/multi-vm-k8s`

| Component   | Pod         | Node (edit YAML if yours differ) |
|------------|-------------|-----------------------------------|
| Orderer    | orderer     | worker2 (desktop-worker2)         |
| Peer0 Org1 | peer0-org1  | control-plane (desktop-control-plane) |
| Peer0 Org2 | peer0-org2  | worker1 (desktop-worker)          |

**Three physical nodes (each with its own IP):** The same approach applies. Peers and the orderer communicate via Kubernetes Services and cluster DNS, not node IPs. You do **not** need to add anything to `/etc/hosts` on the nodes or on your laptop. When using port-forward, you connect to `localhost`; TLS hostname override handles cert verification.

---

## Prerequisites

- Kubernetes cluster with at least 3 nodes. Edit `affinity` in `orderer.yaml`, `peer0-org1.yaml`, and `peer0-org2.yaml` if your node names differ.
- Fabric binaries and config. From the **parent** of `fabric-samples`:
  ```bash
  curl -sSLO https://raw.githubusercontent.com/hyperledger/fabric/main/scripts/install-fabric.sh && chmod +x install-fabric.sh
  ./install-fabric.sh binary docker
  ```
- Generate crypto and genesis block (required for Step 1). **Do not run `./network.sh down` before Step 1**—that removes the crypto and genesis block.

  **Option A – Using test-network (needs Docker):**
  ```bash
  cd /home/djahid/fabric-samples/test-network
  ./network.sh up
  ```

  **Option B – Without Docker (if `network.sh up` does not create the files):**  
  If the `ls` checks below show the files are missing, use the standalone script. It only needs Fabric binaries (`fabric-samples/bin`); no Docker.
  ```bash
  cd /home/djahid/fabric-samples/multi-vm-k8s
  chmod +x generate-crypto.sh
  ./generate-crypto.sh
  ```
  Then continue with Step 1.

  **Verify before Step 1:** the following must exist. If they do not, use Option B or fix Option A (run from `test-network`, ensure `fabric-samples/bin` and `fabric-samples/config` exist, Docker running).
  ```bash
  ls /home/djahid/fabric-samples/test-network/system-genesis-block/genesis.block
  ls /home/djahid/fabric-samples/test-network/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp
  ```

---

## Step 1: Create Kubernetes secrets

The script reads crypto and the genesis block from test-network. **Those files must still exist:** do not run `./network.sh down` until after this step.

```bash
cd /home/djahid/fabric-samples/multi-vm-k8s
chmod +x create-fabric-secrets.sh
./create-fabric-secrets.sh
```

Optionally set `TEST_NETWORK_PATH=/home/djahid/fabric-samples/test-network` and `FABRIC_NS=fabric` if your layout differs.

**If you see "Genesis block not found. Generate crypto first":** That message is from `create-fabric-secrets.sh`. Either (1) you ran `./network.sh down` before this step (down removes the crypto), or (2) the genesis block was never created. **Fix:** run the standalone generator (no Docker needed): `cd /home/djahid/fabric-samples/multi-vm-k8s && ./generate-crypto.sh`, then run `./create-fabric-secrets.sh` again. Ensure `fabric-samples/bin` contains `configtxgen` and `cryptogen` (from `install-fabric.sh binary`).

---

## Step 2: Apply manifests

Apply the namespace, **external builder ConfigMap** (peers mount it and will fail without it), orderer, and peers. Use `microk8s kubectl` if that is your cluster.

```bash
kubectl apply -f namespace.yaml
kubectl apply -f chaincode-external-builder.yaml -n fabric
kubectl apply -f orderer.yaml
kubectl apply -f peer0-org1.yaml
kubectl apply -f peer0-org2.yaml
```

Verify pods (and node placement if desired):

```bash
kubectl get pods -n fabric -o wide
```

---

## Step 3: Port-forward (only if you run peer CLI from the host)

Port-forward is **only needed** when you run the `peer` (or `configtxgen` for channel create) CLI from your laptop or the master. If you run all peer and orderer communication **from inside the cluster** (see [Running without port-forward](#running-without-port-forward) below), you can skip port-forward and `/etc/hosts` entirely.

**When using the host CLI**, keep these running in the background (or in a separate terminal):

```bash
kubectl -n fabric port-forward svc/orderer-example-com 7050:7050 &
kubectl -n fabric port-forward svc/peer0-org1-example-com 7051:7051 &
kubectl -n fabric port-forward svc/peer0-org2-example-com 9051:9051 &
```

**On MicroK8s**, if you see `x509: cannot validate certificate ... doesn't contain any IP SANs` when running port-forward (or logs/exec), fix the kubelet certificate on **every node** so port-forward works with no flags. See [Fix MicroK8s kubelet certificate](#fix-microk8s-kubelet-certificate) below.

### Fix host TLS so you can run peer CLI from the host

If invoke/query from the host fails with TLS errors (e.g. "certificate is valid for peer0.org1.example.com, not peer0.org1.com"), do this **once** on the machine where you run the `peer` CLI (e.g. the master or your laptop):

Add the Fabric hostnames to `/etc/hosts` so they resolve to 127.0.0.1 (port-forward listens on localhost). Then the peer CLI will connect to 127.0.0.1 and verify TLS against the names in the certs, which match.

```bash
# On the host where you run 'peer' (requires sudo)
echo '127.0.0.1 orderer.example.com peer0.org1.example.com peer0.org2.example.com' | sudo tee -a /etc/hosts
```

Use **one line** so you don’t duplicate entries if you run it again. To add them separately:

```bash
sudo sed -i '/orderer.example.com/d' /etc/hosts
sudo sed -i '/peer0.org1.example.com/d' /etc/hosts
sudo sed -i '/peer0.org2.example.com/d' /etc/hosts
echo '127.0.0.1 orderer.example.com peer0.org1.example.com peer0.org2.example.com' | sudo tee -a /etc/hosts
```

Then run invoke/query **from the host** using those hostnames (see Step 7 “From the host” below). You do **not** need to unset `CORE_PEER_HOSTNAME`; the certs are issued for these names, so TLS will succeed.

### Running without port-forward

You can do **all** channel and chaincode steps (create channel, join, install, approve, commit, invoke, query) **from inside the cluster** using `kubectl exec` into the peer pods. No port-forward and no `/etc/hosts` on the host. The host is only used for:

- **configtxgen** (run on the host; it only reads config and does not connect to the network)
- **kubectl cp** to copy channel tx, block, chaincode package, and Admin MSP tarballs into the pods

**Channel create (no port-forward):** Run configtxgen on the host to produce the channel tx, then copy the tx and the orderer TLS CA into peer0-org1, ensure Admin MSP is in the pod, and run `peer channel create` inside the pod talking to `orderer-example-com:7050`:

```bash
# On the host (from test-network)
cd /home/djahid/fabric-samples/test-network
mkdir -p channel-artifacts
export CHANNEL_NAME=mychannel3
export FABRIC_CFG_PATH=$PWD/configtx
configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ./channel-artifacts/${CHANNEL_NAME}.tx -channelID $CHANNEL_NAME

# Copy tx and orderer CA into peer0-org1; copy Admin MSP if not already in the pod
TEST_NETWORK=$PWD
NS=fabric
ORDERER_CA=$TEST_NETWORK/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
P1=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org1-' | head -1)

microk8s kubectl -n $NS cp "$TEST_NETWORK/channel-artifacts/${CHANNEL_NAME}.tx" "$P1:/tmp/${CHANNEL_NAME}.tx" -c peer
microk8s kubectl -n $NS cp "$ORDERER_CA" "$P1:/tmp/orderer-tls-ca.pem" -c peer
# If Admin MSP not in /tmp, package and copy it:
# cd "$TEST_NETWORK/organizations/peerOrganizations/org1.example.com/users" && tar cf /tmp/org1-admin-msp.tar Admin@org1.example.com && cd -
# microk8s kubectl -n $NS cp /tmp/org1-admin-msp.tar "$P1:/tmp/" -c peer

# Create channel from inside the pod (talks to orderer via cluster DNS)
microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c 'cd /tmp && tar xf org1-admin-msp.tar 2>/dev/null; true; CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer channel create -o orderer-example-com:7050 -c '"$CHANNEL_NAME"' -f /tmp/'"$CHANNEL_NAME"'.tx --outputBlock /tmp/'"$CHANNEL_NAME"'.block --tls --cafile /tmp/orderer-tls-ca.pem --ordererTLSHostnameOverride orderer.example.com'
```

Then **join** both peers from inside the cluster. The block is now in peer0-org1 at `/tmp/${CHANNEL_NAME}.block`. Copy it to the host (or to peer0-org2 directly), then use the standard "join from inside the cluster" steps (copy block + Admin MSPs to both pods, exec channel join). Example: copy block from peer0-org1 to host, then to both pods for join:

```bash
BLOCK=$TEST_NETWORK/channel-artifacts/${CHANNEL_NAME}.block
P2=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org2-' | head -1)
microk8s kubectl -n $NS cp "$P1:/tmp/${CHANNEL_NAME}.block" "$BLOCK" -c peer
# Then run the join steps (copy block + Admin MSPs to P1 and P2, then exec channel join as in Step 5).
```

**Join, chaincode install, approve, commit, invoke, query:** Use the existing **"from inside the cluster"** or **"install from inside the cluster"** instructions in Steps 4–7. They already use `orderer-example-com` and peer service names; no port-forward is involved. You still need the **CoreDNS rewrite** so `peer0.org1.example.com` and `peer0.org2.example.com` resolve inside the cluster for commit and invoke (see [Optional: DNS for TLS](#optional-dns-for-tls-cluster-admin)).

---

## Step 4: Create channel

All peer and configtxgen commands in this and the following steps are run from **test-network** so `organizations/` and `configtx/` are present.

```bash
cd /home/djahid/fabric-samples/test-network
mkdir -p channel-artifacts
export CHANNEL_NAME=mychannel3
export ORDERER_CA=$PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
export PEER0_ORG1_CA=$PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export PEER0_ORG2_CA=$PWD/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
```

Create channel transaction (configtxgen uses `configtx/`):

```bash
export FABRIC_CFG_PATH=$PWD/configtx
configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ./channel-artifacts/mychannel3.tx -channelID mychannel3
```

Create channel (peer must sign as an org Admin; use Org1 Admin):

```bash
export FABRIC_CFG_PATH=$PWD/../config
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
peer channel create -o localhost:7050 -c mychannel3 -f ./channel-artifacts/mychannel3.tx --outputBlock ./channel-artifacts/mychannel3.block --tls --cafile $ORDERER_CA --ordererTLSHostnameOverride orderer.example.com
```

---

## Step 5: Join peers to channel

```bash
export FABRIC_CFG_PATH=$PWD/../config
```

Org1 (run from test-network). If the peer CLI ignores `CORE_PEER_TLS_HOSTNAME_OVERRIDE` and you see “not peer0.org1.com”, use the **hosts workaround** below so the connection hostname matches the cert.

**Option A – With hosts workaround (recommended if override fails)**  
On the machine where you run the peer CLI (e.g. master), add once:
```bash
sudo bash -c 'echo "127.0.0.1 peer0.org1.example.com peer0.org2.example.com orderer.example.com" >> /etc/hosts'
```
Then use the cert hostname as the peer address:
```bash
export CORE_PEER_ADDRESS=peer0.org1.example.com:7051
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG1_CA
export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
peer channel join -b ./channel-artifacts/mychannel3.block
```

**Option B – Using localhost and override**
```bash
export CORE_PEER_ADDRESS=localhost:7051
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG1_CA
export CORE_PEER_TLS_HOSTNAME_OVERRIDE=peer0.org1.example.com
export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
peer channel join -b ./channel-artifacts/mychannel3.block
```

Org2 (after Option A, same hosts; use cert hostname as address):
```bash
export CORE_PEER_ADDRESS=peer0.org2.example.com:9051
export CORE_PEER_LOCALMSPID=Org2MSP
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG2_CA
export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp
peer channel join -b ./channel-artifacts/mychannel3.block
```

Confirm (optional):

```bash
peer channel list
peer channel getinfo -c mychannel3
```

**If you get "certificate is valid for ... not peer0.org1.com"** when joining from the host, use **join from inside the cluster** with the **Admin** identity (JoinChain must be signed by an admin). Run from the master:

```bash
TEST_NETWORK=/home/djahid/fabric-samples/test-network
BLOCK=$TEST_NETWORK/channel-artifacts/mychannel3.block
NS=fabric

# Package Admin MSPs for copy into pods
cd "$TEST_NETWORK/organizations/peerOrganizations/org1.example.com/users" && tar cf /tmp/org1-admin-msp.tar Admin@org1.example.com && cd -
cd "$TEST_NETWORK/organizations/peerOrganizations/org2.example.com/users" && tar cf /tmp/org2-admin-msp.tar Admin@org2.example.com && cd -

P1=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org1-' | head -1)
P2=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org2-' | head -1)

microk8s kubectl -n $NS cp "$BLOCK" "$P1:/tmp/mychannel3.block" -c peer
microk8s kubectl -n $NS cp "$BLOCK" "$P2:/tmp/mychannel3.block" -c peer
microk8s kubectl -n $NS cp /tmp/org1-admin-msp.tar "$P1:/tmp/" -c peer
microk8s kubectl -n $NS cp /tmp/org2-admin-msp.tar "$P2:/tmp/" -c peer

# Join as Admin (peer identity lacks OU=admin)
microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c 'cd /tmp && tar xf org1-admin-msp.tar && CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer channel join -b /tmp/mychannel3.block'
microk8s kubectl -n $NS exec deployment/peer0-org2 -c peer -- sh -c 'cd /tmp && tar xf org2-admin-msp.tar && CORE_PEER_ADDRESS=localhost:9051 CORE_PEER_LOCALMSPID=Org2MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org2.example.com/msp peer channel join -b /tmp/mychannel3.block'
```

**Channel list / getinfo from the host** hit the same TLS "not peer0.org1.com" issue. Run them **inside a peer pod** (Admin MSP is already in `/tmp` from the join above):

```bash
NS=fabric
# List channels (from peer0-org1; use same Admin MSP path as join)
microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer channel list'
# Channel getinfo
microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer channel getinfo -c mychannel3'
```

If `/tmp/Admin@org1.example.com` is missing (pod was restarted), copy the Admin MSP tarball into the pod again and unpack it, then run the commands above.

---

## Step 6: Deploy external chaincode (asset-transfer-basic)

### 6.1 Apply external builder and restart peers

```bash
kubectl apply -f /home/djahid/fabric-samples/multi-vm-k8s/chaincode-external-builder.yaml -n fabric
kubectl rollout restart deployment/peer0-org1 deployment/peer0-org2 -n fabric
```

Wait for pods to be ready.

### 6.2 Build chaincode image

**Multi-node clusters (e.g. MicroK8s with worker nodes):** Worker nodes cannot pull a local image; only the node where you ran `docker build` has it. Either use a registry (see below) or **load the image on every node** (no registry).

#### Option A: No registry – load image on each node

1. Build and save the image on a machine that has Docker:

```bash
cd /home/djahid/fabric-samples/asset-transfer-basic/chaincode-external
docker build -t asset-transfer-basic:1.0 .
docker save asset-transfer-basic:1.0 -o asset-transfer-basic-1.0.tar
```

2. Copy the tarball to **every** node that can run the chaincode pod (master and workers), e.g. `scp asset-transfer-basic-1.0.tar user@worker1:/tmp/`.

3. On **each** of those nodes, import the image into MicroK8s’s containerd:

```bash
sudo microk8s ctr image import /tmp/asset-transfer-basic-1.0.tar
```

4. Keep `chaincode-basic.yaml` with `image: asset-transfer-basic:1.0` and `imagePullPolicy: IfNotPresent`. The pod will use the locally imported image on whichever node it is scheduled.

**Tip:** To run the chaincode only on the master (so you only load the image there), add under the deployment’s `spec.template.spec` a `nodeSelector` matching the master, e.g. `kubernetes.io/hostname: <master-node-name>` (see `kubectl get nodes`).

#### Option B: Use a container registry

1. Build the image (as above), then tag and push (replace `<registry>` / `<username>` with your registry, e.g. `docker.io/myuser`):

```bash
docker tag asset-transfer-basic:1.0 <registry>/asset-transfer-basic:1.0
docker push <registry>/asset-transfer-basic:1.0
```

2. Edit `chaincode-basic.yaml`: set `image` to the full registry image (e.g. `docker.io/myuser/asset-transfer-basic:1.0`). For a private registry add an `imagePullSecrets` entry.

**Single-node / Docker Desktop K8s:** You can use the local image `asset-transfer-basic:1.0` and skip both options; the cluster uses the same Docker daemon.

### 6.3 Create external package and deploy chaincode pod

```bash
cd /home/djahid/fabric-samples/multi-vm-k8s
chmod +x package-cc-external.sh
./package-cc-external.sh basic 1.0
kubectl apply -f chaincode-basic.yaml -n fabric
```

### 6.4 Install package on both peers

If the host peer CLI fails with "not peer0.org1.com", **install from inside the cluster** (copy package into each pod, then run install with Admin MSP):

```bash
NS=fabric
CC_PKG=/home/djahid/fabric-samples/multi-vm-k8s/basic_1.0.tar.gz
P1=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org1-' | head -1)
P2=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org2-' | head -1)

# Copy package into both pods
microk8s kubectl -n $NS cp "$CC_PKG" "$P1:/tmp/basic_1.0.tar.gz" -c peer
microk8s kubectl -n $NS cp "$CC_PKG" "$P2:/tmp/basic_1.0.tar.gz" -c peer

# Ensure Admin MSP is in /tmp (if pod was restarted, copy and unpack org1/org2 Admin tarballs first)
# Then install as Admin
microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer lifecycle chaincode install /tmp/basic_1.0.tar.gz'
microk8s kubectl -n $NS exec deployment/peer0-org2 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:9051 CORE_PEER_LOCALMSPID=Org2MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org2.example.com/msp peer lifecycle chaincode install /tmp/basic_1.0.tar.gz'
```

If `/tmp/Admin@org1.example.com` (or org2) is missing, copy the Admin MSP tarballs into the pods and unpack (same as in the channel-join-from-cluster steps), then run the install commands above.

**Alternatively**, from test-network with port-forwards and working TLS:

```bash
cd /home/djahid/fabric-samples/test-network
export CORE_PEER_ADDRESS=localhost:7051
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE=$PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
peer lifecycle chaincode install /home/djahid/fabric-samples/multi-vm-k8s/basic_1.0.tar.gz
# Same for Org2 with 9051 and org2 MSP paths.
```

### 6.5 Get Package ID and set in chaincode deployment

From inside the cluster (if host CLI has TLS issues):

```bash
microk8s kubectl -n fabric exec deployment/peer0-org1 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer lifecycle chaincode queryinstalled'
```

From the host (when TLS works):

```bash
export CORE_PEER_ADDRESS=localhost:7051
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE=$PEER0_ORG1_CA
export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
peer lifecycle chaincode queryinstalled
```

Copy the Package ID (e.g. `basic_1.0:59ef6e0a2e6cc...`). Edit `chaincode-basic.yaml`: set the `CHAINCODE_ID` env value to that Package ID. Then:

```bash
kubectl apply -f /home/djahid/fabric-samples/multi-vm-k8s/chaincode-basic.yaml -n fabric
kubectl rollout restart deployment/basic-cc -n fabric
```

### 6.6 Approve and commit chaincode

**Path:** All `peer` commands that use `CORE_PEER_MSPCONFIGPATH` or `ORDERER_CA` must use paths under **test-network** (where the crypto is), not multi-vm-k8s. Run from test-network: `cd /home/djahid/fabric-samples/test-network`.

**If the host peer CLI hits TLS "not peer0.org1.com", run approve and commit from inside the cluster** (see below).

**From the host** (from test-network; port-forwards and TLS working):

```bash
cd /home/djahid/fabric-samples/test-network
export CHANNEL_NAME=mychannel3
export CC_NAME=basic
export CC_VERSION=1.0
export CC_SEQUENCE=1
export ORDERER_CA=$PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
export PEER0_ORG1_CA=$PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export PEER0_ORG2_CA=$PWD/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
export PACKAGE_ID=<paste-the-package-id-from-queryinstalled>
export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
# Approve Org1, then Org2, then commit (same as below but with localhost and the above env).
```

**From inside the cluster** (avoids host TLS; need orderer CA in the pod):

Copy the orderer TLS CA into a peer pod, then run approve (once per org) and commit from that pod. Replace `$PACKAGE_ID` with your actual package ID.

```bash
TEST_NETWORK=/home/djahid/fabric-samples/test-network
NS=fabric
ORDERER_CA=$TEST_NETWORK/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
P1=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org1-' | head -1)
P2=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org2-' | head -1)

# Copy orderer CA and both peer TLS CAs into peer0-org1 (for approve + commit)
ORG1_TLS=$TEST_NETWORK/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
ORG2_TLS=$TEST_NETWORK/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
microk8s kubectl -n $NS cp "$ORDERER_CA" "$P1:/tmp/orderer-tls-ca.pem" -c peer
microk8s kubectl -n $NS cp "$ORDERER_CA" "$P2:/tmp/orderer-tls-ca.pem" -c peer
microk8s kubectl -n $NS cp "$ORG1_TLS" "$P1:/tmp/org1-tls.crt" -c peer
microk8s kubectl -n $NS cp "$ORG2_TLS" "$P1:/tmp/org2-tls.crt" -c peer
# (If Admin MSP not in /tmp, copy and unpack org1/org2 Admin tarballs as in the channel-join steps.)

# Approve for Org1 (replace PACKAGE_ID_HERE with your package ID)
microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer lifecycle chaincode approveformyorg -o orderer-example-com:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile /tmp/orderer-tls-ca.pem --channelID mychannel3 --name basic --version 1.0 --package-id PACKAGE_ID_HERE --sequence 1'

# Approve for Org2
microk8s kubectl -n $NS exec deployment/peer0-org2 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:9051 CORE_PEER_LOCALMSPID=Org2MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org2.example.com/msp peer lifecycle chaincode approveformyorg -o orderer-example-com:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile /tmp/orderer-tls-ca.pem --channelID mychannel3 --name basic --version 1.0 --package-id PACKAGE_ID_HERE --sequence 1'

# Commit (from peer0-org1). Use cert hostnames so TLS matches; requires CoreDNS rewrite (see Optional: DNS for TLS).
microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer lifecycle chaincode commit -o orderer-example-com:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile /tmp/orderer-tls-ca.pem --channelID mychannel3 --name basic --version 1.0 --sequence 1 --peerAddresses peer0.org1.example.com:7051 --tlsRootCertFiles /tmp/org1-tls.crt --peerAddresses peer0.org2.example.com:9051 --tlsRootCertFiles /tmp/org2-tls.crt'
```

Replace both `PACKAGE_ID_HERE` strings with your actual package ID (e.g. `basic_1.0:59ef6e0a...`). **Channel not found:** If approve fails with "channel 'mychannel3' not found", the orderer may not have that channel (e.g. orderer was recreated). Use a **new channel name** and follow [Recreate channel with a new name](#recreate-channel-with-a-new-name) below. **Commit TLS:** The commit command must use `peer0.org1.example.com` and `peer0.org2.example.com` (not the K8s service names) so the peer TLS certs match. Apply the CoreDNS rewrite (see [Optional: DNS for TLS](#optional-dns-for-tls-cluster-admin)) so those hostnames resolve to the Fabric services, then run the commit command above.

---

## Recreate channel with a new name

Use this when the orderer no longer has the channel (e.g. after orderer restart/recreate). Pick a **new channel name** (e.g. `mychannel3`) to avoid conflicts.

**Option A – Without port-forward (recommended):** Create the channel from inside a peer pod so the orderer is reached via cluster DNS. See [Running without port-forward](#running-without-port-forward): run configtxgen on the host, copy the tx and orderer CA into peer0-org1, then run `peer channel create -o orderer-example-com:7050 ...` inside the pod. Then do step 3 (join) below.

**Option B – With port-forward:** Ensure orderer port-forward is running, then create the channel from the host:

```bash
microk8s kubectl -n fabric port-forward svc/orderer-example-com 7050:7050 &
```

```bash
cd /home/djahid/fabric-samples/test-network
export CHANNEL_NAME=mychannel3
export ORDERER_CA=$PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
export FABRIC_CFG_PATH=$PWD/configtx
configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ./channel-artifacts/${CHANNEL_NAME}.tx -channelID $CHANNEL_NAME
export FABRIC_CFG_PATH=$PWD/../config
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_MSPCONFIGPATH=$PWD/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
peer channel create -o localhost:7050 -c $CHANNEL_NAME -f ./channel-artifacts/${CHANNEL_NAME}.tx --outputBlock ./channel-artifacts/${CHANNEL_NAME}.block --tls --cafile $ORDERER_CA --ordererTLSHostnameOverride orderer.example.com
```

**3. Join both peers from inside the cluster** (copy block and Admin MSPs, then join as Admin):

```bash
TEST_NETWORK=/home/djahid/fabric-samples/test-network
CHANNEL_NAME=mychannel3
BLOCK=$TEST_NETWORK/channel-artifacts/${CHANNEL_NAME}.block
NS=fabric

cd "$TEST_NETWORK/organizations/peerOrganizations/org1.example.com/users" && tar cf /tmp/org1-admin-msp.tar Admin@org1.example.com && cd -
cd "$TEST_NETWORK/organizations/peerOrganizations/org2.example.com/users" && tar cf /tmp/org2-admin-msp.tar Admin@org2.example.com && cd -

P1=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org1-' | head -1)
P2=$(microk8s kubectl -n $NS get pods --no-headers -o custom-columns=":metadata.name" | grep '^peer0-org2-' | head -1)

microk8s kubectl -n $NS cp "$BLOCK" "$P1:/tmp/${CHANNEL_NAME}.block" -c peer
microk8s kubectl -n $NS cp "$BLOCK" "$P2:/tmp/${CHANNEL_NAME}.block" -c peer
microk8s kubectl -n $NS cp /tmp/org1-admin-msp.tar "$P1:/tmp/" -c peer
microk8s kubectl -n $NS cp /tmp/org2-admin-msp.tar "$P2:/tmp/" -c peer

microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c "cd /tmp && tar xf org1-admin-msp.tar && CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer channel join -b /tmp/${CHANNEL_NAME}.block"
microk8s kubectl -n $NS exec deployment/peer0-org2 -c peer -- sh -c "cd /tmp && tar xf org2-admin-msp.tar && CORE_PEER_ADDRESS=localhost:9051 CORE_PEER_LOCALMSPID=Org2MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org2.example.com/msp peer channel join -b /tmp/${CHANNEL_NAME}.block"
```

**4. Use the new channel name everywhere after this:** approve, commit, invoke, and query must use `CHANNEL_NAME=mychannel3` (or whatever you chose). For approve/commit from inside the pods, pass `--channelID mychannel3` and use the same block/Admin MSP paths as before.

---

## Step 7: Invoke and query chaincode (test the network)

Use your **channel name** (e.g. `mychannel3`) and **chaincode name** (e.g. `basic`). If the host peer CLI has TLS issues, run invoke and query **from inside a peer pod** as below.

**From inside the cluster** (recommended if host CLI fails TLS):

Ensure orderer CA and peer TLS CAs are in the pod (same as for approve/commit). Then from the master:

```bash
NS=fabric
CHAN=mychannel3
CC_NAME=basic

# Seed the ledger (InitLedger; needs orderer + both peers; use cert hostnames, CoreDNS required)
microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer chaincode invoke -o orderer-example-com:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile /tmp/orderer-tls-ca.pem -C '"$CHAN"' -n '"$CC_NAME"' --peerAddresses peer0.org1.example.com:7051 --tlsRootCertFiles /tmp/org1-tls.crt --peerAddresses peer0.org2.example.com:9051 --tlsRootCertFiles /tmp/org2-tls.crt -c '\''{"function":"InitLedger","Args":[]}'\'''

# Query all assets (only needs one peer; localhost is enough)
microk8s kubectl -n $NS exec deployment/peer0-org1 -c peer -- sh -c 'CORE_PEER_ADDRESS=localhost:7051 CORE_PEER_LOCALMSPID=Org1MSP CORE_PEER_MSPCONFIGPATH=/tmp/Admin@org1.example.com/msp peer chaincode query -C '"$CHAN"' -n '"$CC_NAME"' -c '\''{"Args":["GetAllAssets"]}'\'''
```

If `/tmp/orderer-tls-ca.pem` or `/tmp/org1-tls.crt` are missing, copy them into the pod first (same as in Step 6.6). Apply CoreDNS rewrite so `peer0.org1.example.com` and `peer0.org2.example.com` resolve.

**From the host** (when port-forwards and TLS work):

Requires the [host TLS fix](#fix-host-tls-so-you-can-run-peer-cli-from-the-host) above: add `orderer.example.com`, `peer0.org1.example.com`, and `peer0.org2.example.com` to `/etc/hosts` pointing to `127.0.0.1` on the machine where you run `peer`. Then use those hostnames so TLS verification matches the certs:

```bash
cd /home/djahid/fabric-samples/test-network
export CHANNEL_NAME=mychannel3
export CC_NAME=basic
export ORDERER_CA=$PWD/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
export PEER0_ORG1_CA=$PWD/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export PEER0_ORG2_CA=$PWD/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
peer chaincode invoke -o orderer.example.com:7050 --ordererTLSHostnameOverride orderer.example.com --tls --cafile $ORDERER_CA -C $CHANNEL_NAME -n $CC_NAME --peerAddresses peer0.org1.example.com:7051 --tlsRootCertFiles $PEER0_ORG1_CA --peerAddresses peer0.org2.example.com:9051 --tlsRootCertFiles $PEER0_ORG2_CA -c '{"function":"InitLedger","Args":[]}'
peer chaincode query -C $CHANNEL_NAME -n $CC_NAME -c '{"Args":["GetAllAssets"]}'
```

**Chaincode pod in ImagePullBackOff:** The image is not available on the node where the pod is scheduled. **No registry:** On each node (master and workers that can run the pod), run `sudo microk8s ctr image import /path/to/asset-transfer-basic-1.0.tar` after building and saving the image with Docker and copying the tar to that node. See **6.2 Option A**. **With a registry:** Push the image and set the full image name in `chaincode-basic.yaml`. See **6.2 Option B**.

**Host invoke/query: "certificate is valid for ... not peer0.org1.com":** The CLI is verifying against a hostname that doesn’t match the cert. **Fix:** On the host where you run `peer`, add the Fabric hostnames to `/etc/hosts` pointing to 127.0.0.1 and use those hostnames in the command. See [Fix host TLS so you can run peer CLI from the host](#fix-host-tls-so-you-can-run-peer-cli-from-the-host). Then use `--peerAddresses peer0.org1.example.com:7051` and `peer0.org2.example.com:9051` (and `-o orderer.example.com:7050`). Alternatively run invoke/query **from inside the cluster** (Step 7 “From inside the cluster”).

**Invoke fails with "connection refused" to basic-cc:9999:** The chaincode pod is not accepting connections. (1) Check the pod: `kubectl get pods -n fabric -l app=basic-cc` – must be Running. (2) Check logs: `kubectl logs -n fabric deployment/basic-cc -c chaincode` – chaincode must be listening on 9999. (3) Ensure `CHAINCODE_ID` in `chaincode-basic.yaml` matches the Package ID from `peer lifecycle chaincode queryinstalled` (same ID used in approve/commit). Update the YAML, then `kubectl apply -f chaincode-basic.yaml -n fabric` and `kubectl rollout restart deployment/basic-cc -n fabric`; wait for the pod to be Ready before invoking again.

---

## Troubleshooting: Genesis block / organizations not created

If after running `./network.sh up` the verification `ls` commands show no files, `network.sh up` did not create the crypto. Common causes:

- **Wrong directory** – Run `./network.sh up` from inside test-network: `cd /home/djahid/fabric-samples/test-network` then `./network.sh up`.
- **Fabric binaries missing** – The script needs `fabric-samples/bin` (peer, configtxgen, cryptogen) and `fabric-samples/config`. From the **parent** of fabric-samples run: `./install-fabric.sh binary`.
- **Docker** – `network.sh up` uses Docker; if Docker is not running or images fail to pull, the script can fail before or after creating artifacts.

**Fix without Docker:** Use the standalone generator (only needs Fabric binaries):

```bash
cd /home/djahid/fabric-samples/multi-vm-k8s
chmod +x generate-crypto.sh
./generate-crypto.sh
```

Then run Step 1 (`./create-fabric-secrets.sh`).

---

## Fix MicroK8s kubelet certificate

If you see:
`Error from server: Get "https://192.168.2.15:10250/...": tls: failed to verify certificate: x509: cannot validate certificate for 192.168.2.15 because it doesn't contain any IP SANs`

when running **port-forward**, **logs**, or **exec**, the kubelet's TLS certificate doesn't list the node's IP. Fix it by running the script below on **every node** (master and workers).

**1. Copy the script to each node** (if multi-vm-k8s is only on the master):

```bash
scp /home/djahid/fabric-samples/multi-vm-k8s/fix-microk8s-kubelet-cert.sh worker1-virtualbox:
scp /home/djahid/fabric-samples/multi-vm-k8s/fix-microk8s-kubelet-cert.sh worker2-virtualbox:
```

**2. On each node, run with sudo** (script auto-detects this node's IP, or pass the IP):

```bash
cd /home/djahid/fabric-samples/multi-vm-k8s
chmod +x fix-microk8s-kubelet-cert.sh
sudo ./fix-microk8s-kubelet-cert.sh
# Or:  sudo ./fix-microk8s-kubelet-cert.sh 192.168.2.15
```

**3. Run on the master and every worker.** Then try port-forward again:

```bash
microk8s kubectl -n fabric port-forward svc/orderer-example-com 7050:7050 &
microk8s kubectl -n fabric port-forward svc/peer0-org1-example-com 7051:7051 &
microk8s kubectl -n fabric port-forward svc/peer0-org2-example-com 9051:9051 &
```

**If the x509 error still appears** after the script and a short wait, do a **full MicroK8s stop/start on each node** so the kubelet restarts from scratch and can request a new serving cert with the node IP. On **each node** (one at a time, or workers first then master):

```bash
sudo microk8s stop
sudo microk8s start
```

Wait until the node is Ready (`kubectl get nodes`). Then try port-forward again from the master. Alternatively, run the fix script with `--full-restart` on each node so it adds `--node-ip` (if needed) and then does the full stop/start for you:

```bash
sudo ./fix-microk8s-kubelet-cert.sh --full-restart
```

**If the error still persists:** Some environments require a full node cycle and re-join so the kubelet gets a new serving certificate with the node IP in SANs. For **MicroK8s** the kubelet args live in `/var/snap/microk8s/current/args/kubelet` (ensure `--node-ip=<that node's IP>` is set on each node). Then drain each worker, reboot it, remove it from the cluster, and re-join it. **Full step-by-step instructions:** see [MICROK8S-DRAIN-REJOIN.md](MICROK8S-DRAIN-REJOIN.md).

---

## Troubleshooting: Orderer in CrashLoopBackOff

If the orderer pod is `BackOff restarting failed container orderer`, check the logs:

```bash
kubectl logs -n fabric deployment/orderer -c orderer --tail=100
kubectl logs -n fabric deployment/orderer -c orderer --previous
```

Common causes:
- **"Bootstrap method: 'file' is forbidden, system channel is no longer supported"** – The orderer image is Fabric 3.x, which removed system channel support. The manifests use **Fabric 2.5** images (`fabric-orderer:2.5`, `fabric-peer:2.5`). If you see this panic, ensure you applied the updated YAMLs (no `:latest`) and restart the orderer deployment.
- **Orderer panic: "the block isn't a system channel block because it lacks ConsortiumsConfig"** – The genesis block was produced with a profile that doesn’t create a system channel (e.g. `ChannelUsingRaft`). **Fix:** Re-run `./generate-crypto.sh` (it now uses the bundled configtx with `TwoOrgsOrdererGenesis` when present), then `./create-fabric-secrets.sh`, then restart the orderer so it loads the new secret: `microk8s kubectl rollout restart deployment/orderer -n fabric`.
- **Genesis block mismatch** – Genesis was generated with a different profile or is corrupt. Re-run `./generate-crypto.sh`, then `./create-fabric-secrets.sh`, then restart the orderer deployment so it picks up the new secret.
- **MSP/TLS** – Init containers must complete and extract MSP/TLS into the emptyDir; the main container then reads from `/var/hyperledger/orderer/msp` and `tls`. If the crypto material from test-network is wrong or incomplete, the orderer will fail. Ensure `create-fabric-secrets.sh` ran after a successful `generate-crypto.sh` (or `network.sh up`).

---

## Optional: DNS for TLS (cluster-admin)

If you can edit CoreDNS, add rewrite rules so `orderer.example.com` and peer hostnames resolve to Fabric services. See `coredns-fabric-rewrite.yaml` for the three rewrite lines. Add them inside the `.:53` block (before `forward`), then:

```bash
kubectl rollout restart deployment coredns -n kube-system
```

Then you can run channel/chaincode from a pod in the cluster using service names instead of port-forward.

---

## Customizing node placement

Placement uses node labels: `role=orderer`, `role=org1`, `role=org2`. To change which nodes run which component, edit the `matchExpressions` under `affinity.nodeAffinity` in:
- `orderer.yaml` (role: orderer)
- `peer0-org1.yaml` (role: org1)
- `peer0-org2.yaml` (role: org2)
# multi-vm-k8s
# multi-vm-k8s
# multi-vm-k8s
