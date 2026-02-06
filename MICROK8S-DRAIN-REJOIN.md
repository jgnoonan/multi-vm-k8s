# MicroK8s: Drain, Reboot, and Re-join Nodes (Fix Kubelet Certificate)

Use this procedure when the kubelet x509 error persists after adding `--node-ip` and doing a normal or full MicroK8s restart. Re-joining each node forces the kubelet to obtain a new serving certificate that includes the node’s IP in the SANs.

**Prerequisites**

- You have already added `--node-ip=<this node's IP>` to `/var/snap/microk8s/current/args/kubelet` on **every node** (master and workers). The fix script or manual edit is fine.
- You know your node names and IPs (e.g. from `microk8s kubectl get nodes -o wide`).
- Do **one worker at a time** so the Fabric pods can move to the remaining nodes.

**Node names in this guide:** Replace with your real node names and IPs. Example:

- Master: `master-node` (e.g. 192.168.2.10)
- Worker1: `worker1-virtualbox` (e.g. 192.168.2.11)
- Worker2: `worker2-virtualbox` (e.g. 192.168.2.12)

---

## Step 1: List nodes and note the first worker

From the **master**:

```bash
microk8s kubectl get nodes -o wide
```

Pick one worker to do first (e.g. `worker1-virtualbox`). We’ll call it **WORKER** in the steps below.

---

## Step 2: Drain the worker (from master)

From the **master**, evict pods from that worker so they reschedule elsewhere:

```bash
# Replace WORKER with the node name (e.g. worker1-virtualbox)
microk8s kubectl drain WORKER --ignore-daemonsets --delete-emptydir
```

If you see errors about PodDisruptionBudgets, you can add `--force` (use only if necessary). Wait until the drain completes and the node shows as SchedulingDisabled.

---

## Step 3: On the worker – leave the cluster and reboot

SSH (or log in) to **that worker node**, then:

```bash
# Leave the cluster cleanly
microk8s leave

# Reboot so the kubelet starts fresh with --node-ip and can request a new cert
sudo reboot
```

Wait for the machine to come back up.

---

## Step 4: On the master – remove the node and get a new join command

Back on the **master**:

**4a. Remove the old node object** (use the node name or the IP the cluster used for that node):

```bash
# Replace worker1-virtualbox with your worker’s name or IP as shown by microk8s kubectl get nodes
microk8s kubectl get nodes
microk8s remove-node worker1-virtualbox
```

**4b. Generate a new join token:**

```bash
microk8s add-node
```

Copy the printed `microk8s join ...` line (and use `--worker` if you want that node to be a worker only). The token is short-lived; use it in the next step on the worker.

---

## Step 5: On the worker – re-join the cluster

SSH (or log in) to the **same worker** that you drained and rebooted. Run the join command you got from the master (Step 4b). For example:

```bash
# Use the exact command from microk8s add-node (with --worker if desired)
microk8s join 192.168.2.10:25000/XXXXXXXXXX/YYYYYYYYYY --worker
```

Replace the IP with your **master** node’s IP and the token with the one from `microk8s add-node`.

---

## Step 6: Verify the worker is Ready

On the **master**:

```bash
microk8s kubectl get nodes -o wide
```

Wait until that worker shows `Ready`. Pods (including Fabric) may reschedule onto it.

---

## Step 7: Repeat for the other worker(s)

Repeat **Steps 1–6** for the next worker (e.g. `worker2-virtualbox`): drain it, on that worker run `microk8s leave` and `sudo reboot`, on the master run `remove-node` and `add-node`, then on the worker run `microk8s join ...`.

Do **not** remove or drain the master unless you have a specific procedure for re-adding it (e.g. HA). For a single-master cluster, only drain and re-join **workers**.

---

## Step 8: Re-apply Fabric node labels (required after re-join)

Re-joining removes custom labels. The Fabric deployments schedule by `role=orderer`, `role=org1`, and `role=org2`. From the **master**, label the nodes to match your layout (example: orderer on worker2, peer0-org1 on master, peer0-org2 on worker1):

```bash
# Master usually keeps role=org1 (peer0-org1). If it’s missing:
microk8s kubectl label nodes master-node role=org1 --overwrite

# Worker that should run the orderer (e.g. worker2-virtualbox):
microk8s kubectl label nodes worker2-virtualbox role=orderer --overwrite

# Worker that should run peer0-org2 (e.g. worker1-virtualbox):
microk8s kubectl label nodes worker1-virtualbox role=org2 --overwrite
```

Verify:

```bash
microk8s kubectl get nodes --show-labels | grep -E 'NAME|role='
```

Each of the three nodes should have exactly one of `role=orderer`, `role=org1`, `role=org2`. If a pod is stuck in Pending, check its node affinity and that the target node has the right label.

---

## Step 9: Test port-forward

When all workers are back and Ready and labels are set, from the **master** try:

```bash
microk8s kubectl -n fabric port-forward svc/orderer-example-com 7050:7050 &
microk8s kubectl -n fabric port-forward svc/peer0-org1-example-com 7051:7051 &
microk8s kubectl -n fabric port-forward svc/peer0-org2-example-com 9051:9051 &
```

If you no longer see the x509 “doesn’t contain any IP SANs” error, the fix worked. If Fabric pods are Pending, complete Step 8 (re-apply labels).

---

## Summary (one worker)

| Where    | Action |
|----------|--------|
| Master   | `microk8s kubectl drain WORKER --ignore-daemonsets --delete-emptydir` |
| Worker   | `microk8s leave` then `sudo reboot` |
| Master   | `microk8s remove-node WORKER` then `microk8s add-node` (copy join command) |
| Worker   | `microk8s join <master>:25000/<token> --worker` |
| Master   | `microk8s kubectl get nodes` until worker is Ready |

Then repeat for the next worker.
