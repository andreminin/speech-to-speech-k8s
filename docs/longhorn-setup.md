# Longhorn Storage Setup

This guide documents the installation and configuration of **Longhorn** as the persistent storage layer for the `speech-to-speech-k8s` project, validated in an air-gapped environment with a private container registry (`local-registry:5000`).

## Prerequisites

Before installing Longhorn, ensure the following are in place on **every worker node** (`node1`, `node2`, `node3`):

### 1. `open-iscsi` Installed and Running

Longhorn requires `iscsiadm` to manage block devices. Without it, the Longhorn manager pods will crash with:

failed to execute: nsenter ... iscsiadm --version ... No such file or directory
text


**Install and start the service:**

```bash
sudo apt update
sudo apt install -y open-iscsi
sudo systemctl enable --now iscsid
sudo systemctl status iscsid   # Should show "active (running)"
```

Air-gapped note: If your nodes cannot reach the internet, download the open-iscsi and libopeniscsiusr .deb packages on a connected machine, transfer them, and install with sudo dpkg -i *.deb.
2. Required Kernel Modules

Longhorn also requires the dm_crypt and dm_mod kernel modules. These are typically present by default. Verify with:
bash

lsmod | grep dm_crypt
lsmod | grep dm_mod

If missing, load them:
bash

sudo modprobe dm_crypt

3. Storage Directory

Longhorn expects a data directory on each node where it will store volume replicas. Create it and set appropriate permissions:
bash

sudo mkdir -p /mnt/longhorn
sudo chown root:root /mnt/longhorn
sudo chmod 755 /mnt/longhorn

Ensure the partition has at least 15% free space (as required by the storageMinimalAvailablePercentage setting). Check with:
bash

sudo df -h /mnt/longhorn

Installation
1. Add the Longhorn Helm Repository
bash

helm repo add longhorn https://charts.longhorn.io
helm repo update

2. Prepare longhorn-values.yaml

Because the cluster is air-gapped, all image repositories must point to the local registry (local-registry:5000). The following values also configure:

 - 10G storage network isolation (storageNetwork: "custom")

 - Automatic default disk creation on labeled nodes

 - Ingress for the Longhorn UI (optional)

Create longhorn-values.yaml:
```yaml

global:
  imagePullSecrets:
    - name: local-registry-cred

image:
  longhorn:
    repository: local-registry:5000/longhorn-manager
    tag: v1.12.1
  engine:
    repository: local-registry:5000/longhorn-engine
    tag: v1.12.1
  instanceManager:
    repository: local-registry:5000/longhorn-instance-manager
    tag: v1.12.1
  shareManager:
    repository: local-registry:5000/longhorn-share-manager
    tag: v1.12.1
  ui:
    repository: local-registry:5000/longhorn-ui
    tag: v1.12.1

csi:
  attacher:
    repository: local-registry:5000/csi-attacher
    tag: v4.12.0
  provisioner:
    repository: local-registry:5000/csi-provisioner
    tag: v5.3.0
  resizer:
    repository: local-registry:5000/csi-resizer
    tag: v2.2.1
  snapshotter:
    repository: local-registry:5000/csi-snapshotter
    tag: v8.6.0
  nodeDriverRegistrar:
    repository: local-registry:5000/csi-node-driver-registrar
    tag: v2.17.0
  livenessProbe:
    repository: local-registry:5000/livenessprobe
    tag: v2.19.0

network:
  storageNetwork: "custom"

defaultSettings:
  createDefaultDiskLabeledNodes: true
  defaultDataPath: /mnt/longhorn
  storageOverProvisioningPercentage: 100
  storageMinimalAvailablePercentage: 15

ingress:
  enabled: true
  host: longhorn.local
```
Note: The image tags above are for Longhorn v1.12.1. If you are using a different version, adjust the tags accordingly. You can find the exact tags your Helm chart expects with:
bash

helm show values longhorn/longhorn | grep -A 2 "repository:"

3. Create the Image Pull Secret

Longhorn pods must authenticate with the private registry. Create the secret in the longhorn-system namespace:
```bash
kubectl create namespace longhorn-system
kubectl create secret docker-registry local-registry-cred \
  --docker-server=local-registry:5000 \
  --docker-username=docker-agent \
  --docker-password=V3ga123456 \
  -n longhorn-system
```
4. Install Longhorn
```bash
helm install longhorn longhorn/longhorn \
  --namespace longhorn-system \
  --create-namespace \
  -f longhorn-values.yaml
```
5. Label Worker Nodes for Default Disk

Longhorn automatically creates a default disk on nodes with the label node.longhorn.io/create-default-disk=true. Apply this label to your worker nodes:
```bash
kubectl label node node2 node.longhorn.io/create-default-disk=true
kubectl label node node3 node.longhorn.io/create-default-disk=true
```
    If node1 also has storage capacity and you want to use it, label it as well:
    bash

    kubectl label node node1 node.longhorn.io/create-default-disk=true

After labeling, restart the Longhorn manager pods to trigger disk creation:
```bash
kubectl delete pods -n longhorn-system -l app=longhorn-manager
```
6. Verify Installation

Check that all pods are running:
```bash
kubectl get pods -n longhorn-system
```
Expected output (all Running or Completed):
```text
NAME                                                READY   STATUS    RESTARTS   AGE
csi-attacher-7ccdcf8f47-xxxxx                       1/1     Running   0          5m
csi-provisioner-786c5b7c67-xxxxx                    1/1     Running   0          5m
csi-resizer-75c55d6d45-xxxxx                        1/1     Running   0          5m
csi-snapshotter-55775fb589-xxxxx                    1/1     Running   0          5m
engine-image-ei-493e04e7-xxxxx                      1/1     Running   0          5m
instance-manager-xxxxx                              1/1     Running   0          5m
longhorn-csi-plugin-xxxxx                           3/3     Running   0          5m
longhorn-driver-deployer-xxxxx                      1/1     Running   0          5m
longhorn-manager-xxxxx                              2/2     Running   0          5m
longhorn-ui-xxxxx                                   1/1     Running   0          5m
```
Verify that disks are available on each node:
```bash
kubectl describe nodes.longhorn.io node2 -n longhorn-system | grep -A 10 "Disk Status"
```
You should see:
```text
Disk Status:
  default-disk-xxxxxxxxxxxxxxxx:
    Conditions:
      Status:  True
      Type:    Ready
      Status:  True
      Type:    Schedulable
    Path:      /mnt/longhorn
```
Mirroring Longhorn Images

If you are setting up Longhorn in an air-gapped environment, you must mirror all required container images to your private registry before installation.
Required Images

The following images are required for Longhorn v1.12.1:
Local Name	Public Source
longhorn-manager	docker.io/longhornio/longhorn-manager:v1.12.1
longhorn-engine	docker.io/longhornio/longhorn-engine:v1.12.1
longhorn-instance-manager	docker.io/longhornio/longhorn-instance-manager:v1.12.1
longhorn-share-manager	docker.io/longhornio/longhorn-share-manager:v1.12.1
longhorn-ui	docker.io/longhornio/longhorn-ui:v1.12.1
csi-attacher	docker.io/longhornio/csi-attacher:v4.12.0
csi-provisioner	docker.io/longhornio/csi-provisioner:v5.3.0
csi-resizer	docker.io/longhornio/csi-resizer:v2.2.1
csi-snapshotter	docker.io/longhornio/csi-snapshotter:v8.6.0
csi-node-driver-registrar	docker.io/longhornio/csi-node-driver-registrar:v2.17.0
livenessprobe	docker.io/longhornio/livenessprobe:v2.19.0
Mirroring Script

Use the provided scripts/mirror-images.sh script to pull images from public registries and push them to your local registry:
```bash
./scripts/mirror-images.sh local-registry:5000
```

The script defines a mapping between local repository names and public image sources. For Longhorn v1.12.1, ensure the following entries are present (uncommented):
```bash
declare -A IMAGES=(
  [csi-attacher]="docker.io/longhornio/csi-attacher:v4.12.0"
  [csi-node-driver-registrar]="docker.io/longhornio/csi-node-driver-registrar:v2.17.0"
  [csi-provisioner]="docker.io/longhornio/csi-provisioner:v5.3.0"
  [csi-resizer]="docker.io/longhornio/csi-resizer:v2.2.1"
  [csi-snapshotter]="docker.io/longhornio/csi-snapshotter:v8.6.0"
  [livenessprobe]="docker.io/longhornio/livenessprobe:v2.19.0"
  [longhorn-engine]="docker.io/longhornio/longhorn-engine:v1.12.1"
  [longhorn-instance-manager]="docker.io/longhornio/longhorn-instance-manager:v1.12.1"
  [longhorn-manager]="docker.io/longhornio/longhorn-manager:v1.12.1"
  [longhorn-share-manager]="docker.io/longhornio/longhorn-share-manager:v1.12.1"
  [longhorn-ui]="docker.io/longhornio/longhorn-ui:v1.12.1"
)
```

After running the script, verify the images are available:
```bash
curl -k https://local-registry:5000/v2/_catalog
```

You should see all the repositories listed (e.g., csi-attacher, longhorn-manager, etc.).
Validation: Test PVC and Pod

Before deploying speech services, confirm Longhorn can provision and mount volumes.
1. Create a Test PVC

k8s/storage/longhorn-test-pvc.yaml:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-longhorn-pvc
  namespace: speech
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
```

Apply and watch:
```bash
kubectl apply -f k8s/storage/longhorn-test-pvc.yaml
kubectl get pvc test-longhorn-pvc -n speech -w
```

Wait for STATUS: Bound.
2. Deploy a Test Pod

k8s/storage/longhorn-test-pod.yaml:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-longhorn-pod
  namespace: speech
spec:
  imagePullSecrets:
    - name: local-registry-cred
  containers:
    - name: test
      image: local-registry:5000/cuda:12.9.1-cudnn-runtime-ubuntu24.04
      command: ["sleep", "3600"]
      volumeMounts:
        - name: vol
          mountPath: /data
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: test-longhorn-pvc
```

Apply and verify:
```bash
kubectl apply -f k8s/storage/longhorn-test-pod.yaml
kubectl get pod test-longhorn-pod -n speech -w
```

Once Running, test the mount:
```bash
kubectl exec -it test-longhorn-pod -n speech -- touch /data/hello.txt
kubectl exec -it test-longhorn-pod -n speech -- ls -la /data
```

If you see hello.txt, Longhorn is fully operational.
3. Clean Up
```bash
kubectl delete pod test-longhorn-pod -n speech
kubectl delete pvc test-longhorn-pvc -n speech
```
Troubleshooting
Pods Stuck in ContainerCreating with FailedAttachVolume

Symptoms:
```text
Warning  FailedAttachVolume  attachdetach-controller  AttachVolume.Attach failed: volume is not ready for workloads: volume is currently in detached state with some un-schedulable replicas
```
Cause: The volume has no schedulable replicas, typically because disks are missing or not ready.

Fix:

Verify disks are present and schedulable:
```bash
kubectl describe nodes.longhorn.io node2 -n longhorn-system | grep -A 10 "Disk Status"
```
If disks are missing, ensure the label node.longhorn.io/create-default-disk=true is present and restart the managers:
```bash
kubectl label node node2 node.longhorn.io/create-default-disk=true
kubectl delete pods -n longhorn-system -l app=longhorn-manager
```
If the volume is already faulted, delete the PVC and recreate it.

ImagePullBackOff on Longhorn Pods

Symptoms: Pods show ImagePullBackOff or ErrImagePull.

Cause: The image is missing from the local registry, or the repository path in the Helm values does not match the pushed image.

Fix:

Verify the image exists in the registry:
```bash
curl -k https://local-registry:5000/v2/_catalog
```
Check the exact image tag the pod is trying to pull:
```bash
kubectl describe pod <pod-name> -n longhorn-system | grep "Image:"
```
Ensure your longhorn-values.yaml uses the correct repository and tag. The repository should match how you tagged the image when pushing to the local registry.

Longhorn Manager Crashes with iscsiadm: No such file or directory

Symptoms:
```text
failed to execute: nsenter ... iscsiadm --version ... No such file or directory
```
Cause: open-iscsi is not installed on the host node.

Fix: Install open-iscsi on every worker node as described in the Prerequisites section.
PVC Stuck in Terminating

Symptoms: A PVC remains in Terminating state and cannot be deleted.

Cause: The underlying Longhorn volume is faulted and the finalizer cannot complete.

Fix:

Remove the finalizer from the PVC:
```bash
kubectl patch pvc <pvc-name> -n speech -p '{"metadata":{"finalizers":null}}' --type=merge
```
Delete the PVC:
```bash
kubectl delete pvc <pvc-name> -n speech --force --grace-period=0
```
Delete the underlying Longhorn volume:
```bash
kubectl delete volumes.longhorn.io <volume-name> -n longhorn-system --force --grace-period=0
```
If it doesn't delete, patch it first:
```bash
kubectl patch volumes.longhorn.io <volume-name> -n longhorn-system -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl delete volumes.longhorn.io <volume-name> -n longhorn-system
```
Disk Not Becoming Ready on a Node

Symptoms:
```text
Message: Waiting for disk default-disk-xxx (/mnt/longhorn) on node node3 to be ready
Reason: NodeNotReady
Status: False
```
Cause: The disk path is missing, unwritable, or the partition is full.

Fix:

SSH into the node and verify the directory:
```bash
sudo ls -la /mnt/longhorn
sudo df -h /mnt/longhorn
```
If missing, create it:
```bash
sudo mkdir -p /mnt/longhorn
sudo chown root:root /mnt/longhorn
sudo chmod 755 /mnt/longhorn
```
If the partition is full, free up space or mount a larger disk to /mnt/longhorn.

Restart the Longhorn manager on the node:
```bash
kubectl delete pod -n longhorn-system -l app=longhorn-manager --field-selector spec.nodeName=node3
```
Next Steps

Once Longhorn is validated, proceed to:

Phase B – Deploy speech-llm with a Longhorn PVC for model storage

Phase C – Deploy speech-stt with a Longhorn PVC

Phase D – Deploy speech-tts with a Longhorn PVC

Phase E – Deploy the gateway and run the first end-to-end test

See the main deployment.md for the full deployment sequence.