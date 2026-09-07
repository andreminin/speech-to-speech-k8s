# Node labels (one-time, imperative — not a manifest)

Labeling is a cluster-admin action applied once, not something reconciled
by `kubectl apply`, so it's recorded here as commands rather than YAML.

```bash
kubectl label node node1 gpu-class=small --overwrite
kubectl label node node2 gpu-class=16gb --overwrite
kubectl label node node3 gpu-class=16gb --overwrite
```

These labels are documentation/defense-in-depth only. Actual scheduling in
this 4-node cluster is governed by `nodeName` pinning in each Deployment
(every component is coupled to node-local model storage, so it must land on
a specific physical node, not just "any 16gb-class node"). If a second
16GB-class node is ever added, `gpu-class` labels are what would let a
future manifest float across a real pool instead of hard-pinning.

Verify before proceeding:

```bash
kubectl get nodes --show-labels
kubectl get nodes   # all of node0-node3 must show STATUS Ready
```
