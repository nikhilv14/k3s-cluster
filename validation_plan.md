# Validation Plan: K3s Longhorn & TrueNAS NFS Architecture

This checklist outlines the steps to validate the k3s cluster configuration for a split-storage architecture using Longhorn (always-on) and TrueNAS NFS (bulk/intermittent).

## 1. StorageClasses and Provisioners

### Inspection
- [ ] **Verify Longhorn StorageClass**
  - [ ] Confirm a StorageClass named `longhorn` exists.
  - [ ] Verify it is marked as `(default)`.
  - [ ] Check `provisioner` is `driver.longhorn.io`.
  - [ ] Check `reclaimPolicy` is `Delete` (typical for dynamic provisioning) or `Retain` if explicitly configured.
  - [ ] Check `volumeBindingMode` is `Immediate`.

- [ ] **Verify NFS StorageClass**
  - [ ] Confirm a StorageClass named `nas` (or similar configured name) exists.
  - [ ] Verify it is **not** the default.
  - [ ] Check `provisioner` is `kubernetes.io/nfs` (or the specific CSI driver if used, but standard is `kubernetes.io/nfs` for simple setups).
  - [ ] Confirm `mountOptions` include resilience flags: `vers=4`, `soft` (or `hard` with `intr`), `timeo`, `retrans` to handle NAS downtime gracefully.

### Component Health
- [ ] **Longhorn Availability**
  - [ ] Ensure `longhorn-manager` DaemonSet is running on all nodes (N100, WSL2, T3600).
  - [ ] Confirm all Longhorn pods in `longhorn-system` namespace are `Running`.
  - [ ] Verify the Longhorn UI is accessible (if Ingress/Port-forward is set up) and reports all nodes as "Ready".

- [ ] **NFS Provisioner Availability**
  - [ ] Ensure the NFS provisioner (if external) is running; for built-in `kubernetes.io/nfs`, no specific pod is needed, but the PV must be valid.

## 2. TrueNAS NFS Export Validation (k3s_pool)

### On TrueNAS (T3600 VM)
- [ ] **Export Configuration**
  - [ ] Verify the ZFS dataset `k3s_pool` (or path `/mnt/main/k3s`) is created.
  - [ ] Confirm the NFS Service is running.
  - [ ] specific check: The export path matches exactly what is defined in the K3s PV.
  - [ ] Permissions: Verify `maproot` or `mapall` user is set correctly (often `root` or a specific k3s user) so nodes can read/write.
  - [ ] Network: Verify the export allows connections from the subnets of all k3s nodes (192.168.12.x).

### On K3s Nodes (N100, WSL2, T3600)
- [ ] **Mount Verification**
  - [ ] **N100**: Manually mount the NFS export to a temporary path. Attempt to `touch` a file.
  - [ ] **WSL2**: Manually mount the NFS export. Verify read/write access.
  - [ ] **T3600**: Manually mount the NFS export (loopback check). Verify read/write access.
  - [ ] **Latency Check**: Ensure simple file operations do not hang indefinitely.
  - [ ] **Cleanup**: Unmount temporary paths after testing.

## 3. PV/PVC Wiring Inspection

### Longhorn Wiring
- [ ] **Critical Data PVCs**
  - [ ] Inspect PVCs intended for databases (e.g., `immich-postgres`, `redis`).
  - [ ] Confirm `StorageClass: longhorn`.
  - [ ] Confirm Status is `Bound`.
  - [ ] Verify the associated PV has `driver.longhorn.io` in its spec.

### NAS Wiring
- [ ] **Bulk Data PVs**
  - [ ] Inspect the static PV (e.g., `nas-storage-pv`).
  - [ ] Confirm `spec.nfs.server` matches the TrueNAS IP (192.168.12.50).
  - [ ] Confirm `spec.nfs.path` matches the exported dataset exactly.
  - [ ] Confirm `accessModes` includes `ReadWriteMany` (RWX).

- [ ] **Bulk Data PVCs**
  - [ ] Inspect PVCs for bulk data (e.g., `nas-test-pvc`).
  - [ ] Confirm `StorageClass: nas`.
  - [ ] Confirm it is bound to the correct `nas-storage-pv`.

### Legacy Cleanup
- [ ] Scan for any "Lost" or "Pending" PVCs referencing old IP addresses or non-existent paths.
- [ ] Plan deletion or patch update for any mismatched resources.

## 4. Test Workloads

### Longhorn Workload Test
- [ ] **Deploy**: Create a Pod using a PVC with `storageClassName: longhorn`.
- [ ] **Write**: Enter the pod and write a file (e.g., `/data/test.txt`).
- [ ] **Reschedule**: Delete the Pod (not the PVC) to force a reschedule.
- [ ] **Verify**: When the Pod restarts, confirm `/data/test.txt` still exists and contains the correct data.
- [ ] **Success Criteria**: Pod starts quickly, data persists, Longhorn UI shows volume attached.

### NAS Workload Test
- [ ] **Deploy**: Create a Pod using a PVC with `storageClassName: nas`.
- [ ] **Write**: Write a file from within the Pod.
- [ ] **External Verify**: Log into TrueNAS shell and verify the file appears in the dataset.
- [ ] **Resilience Test (Offline NAS)**:
  - [ ] Power down or disconnect TrueNAS.
  - [ ] Observe the Pod. It should NOT crash but may hang on I/O.
  - [ ] Verify `kubectl get pods` shows the pod as Running (or acceptable state, not Evicted/Error if configured correctly).
  - [ ] Power TrueNAS back on.
  - [ ] Confirm the Pod recovers I/O ability without manual restart.

## 5. Pattern Validation for Immich-like Apps

### Architecture Check
- [ ] **Split Storage Verification**
  - [ ] Review Immich (or representative app) Helm values or Manifests.
  - [ ] **Database/Cache**: Must use `longhorn` SC.
  - [ ] **Photos/Uploads**: Must use `nas` SC.
  - [ ] **Buffer (Optional)**: If implemented, confirm a separate PVC uses `longhorn` for temporary upload staging.

### Capacity & Constraints
- [ ] **Longhorn Capacity**: Check N100 local disk usage. Ensure enough headroom for snapshots/growth of critical DBs.
- [ ] **Node Affinity**:
  - [ ] Confirm Longhorn workloads prefer or require the N100 (if it's the only one with stable local storage for replicas).
  - [ ] Check if Intermittent nodes (WSL2, T3600) have correct taints/labels to prevent them from hosting critical Longhorn replicas if they are not stable.

### Degraded Mode Readiness
- [ ] Verify application behavior when NAS mount is unresponsive.
- [ ] Success: App UI loads (served from Longhorn DB), but images/assets (on NAS) fail to load gracefully (e.g., broken image icons) rather than crashing the entire app.
