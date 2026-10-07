# AGENTS.md — k3sSetup

Context for AI agents and humans working in this repo. Last verified against live cluster: **2026-10-07**.

## What this repo is

Ansible-based provisioning for a homelab k3s HA cluster on Proxmox, plus declarative
manifests for cluster-wide networking and storage. Apps themselves are NOT here —
they deploy via ArgoCD from `git@github.com:nikhilv14/argo-quick-apps.git`.

## Cluster topology

| Node | k8s name | IP | Role | Notes |
|---|---|---|---|---|
| n100 | `k3s-node1` | 192.168.12.51 | control-plane, etcd | Oldest member; NAS mounted at `/mnt/nas-k3s-snapshots`; labeled `homelab/node-type=always-on` |
| — | `k3s-server-nuc` | 192.168.12.110 | control-plane, etcd | Proxmox VM |
| — | `k3s-server-hp-g9` | 192.168.12.132 | control-plane, etcd | Proxmox VM |

- k3s **v1.36.5+k3s1**, flannel **vxlan on UDP 8472** (default)
- SSH: user `nikhil`, key `~/.ssh/id_ed25519` (sudo requires NOPASSWD — it is enabled)
- No worker nodes. The WSL2 agent (`wsl2-debian-worker`) and T3600 agent were
  decommissioned 2026-10-07; their playbooks were deleted.

## VIPs — never depend on node IPs

| VIP | Purpose | Mechanism |
|---|---|---|
| `192.168.12.10:6443` | kube-apiserver | kube-vip v0.9.1 DaemonSet, ARP + leader election (`networking/kube-vip.yaml`) |
| `192.168.12.61` | ingress (HTTP/443) | MetalLB lan-pool `.61-.70` → ingress-nginx LoadBalancer |

Rules:
- kubeconfig and node-join URLs use `https://192.168.12.10:6443` (VIP in tls-san on all servers)
- MetalLB VIPs must stay OUTSIDE the API VIP; lan-pool is `.61-.70`
- Only nodes labeled `homelab/node-type=always-on` announce VIPs and run
  ingress-nginx (currently only k3s-node1)

## Critical gotchas (learned the hard way)

1. **Flannel port mismatch splits the overlay.** All nodes must use the same VXLAN
   port (8472). The old WSL2 workaround was a custom port 48472 via
   `/etc/rancher/k3s/flannel-net-conf.json` on node1. That file is RETIRED. Warning:
   node1's k3s FAILS TO START (`flannel exited: failed to read net conf`) if that
   file is missing — if recreating node1, restore a config with `Port: 8472` or
   remove the file only when k3s tolerates it. Never mix ports across nodes.
2. **kube-vip v0.9.x env vars**: needs BOTH `cp_enable=true` (legacy alias) and
   `vip_controlplane=true`; VIP must be a plain IP + `vip_subnet=32` — embedding
   `/32` in `vip_address` triggers a bogus DNS lookup and crash.
3. **cert-manager CA**: the `ca-root` Certificate MUST have `isCA: true` — without
   it, `internal-ca` issuer fails with `ErrInvalidKeyPair: certificate is not a CA`
   (this bug silently broke ArgoCD/dashboard/Longhorn/Tandoor TLS for ~9 months,
   fixed 2026-10-07). CA duration patched to 10y.
4. **ArgoCD owns app manifests** (auto-sync, selfHeal). kubectl edits to
   ArgoCD-managed resources get reverted — fix in the `argo-quick-apps` Git repo
   and let ArgoCD sync (e.g. tandoor ingress issuer → `internal-ca`).
5. **K8s node name ≠ inventory name** for n100 (`n100` → `k3s-node1`). Handled via
   `k8s_node_name` var.
6. **Longhorn node onboarding checklist** (for any new server node):
   - install `open-iscsi` + `nfs-common` (else longhorn-manager fatal: no iscsiadm)
   - label node `longhorn-system=true` (longhorn-manager DaemonSet nodeSelector)
   - tag Longhorn node + all disks with `ssd` (required by ssd-cache SC
     nodeSelector/diskSelector) — else replicas fail: "disks are unavailable"
   - Longhorn refuses to delete a node CR until the k8s node is gone and
     `allowScheduling=false`; clear finalizers if stuck
7. **Two ingress-class controllers** (traefik vs ingress-nginx) cause conflicts —
   traefik and klipper servicelb are DISABLED in every server's
   `/etc/rancher/k3s/config.yaml` (`disable: [traefik, servicelb]`). Do not remove.

## Storage layout

| StorageClass | Provisioner | Replicas | Notes |
|---|---|---|---|
| `longhorn` | driver.longhorn.io | 2 | **default class** |
| `ssd-cache` | driver.longhorn.io | 2 | requires `ssd` node+disk tags, dataLocality best-effort |
| `nas-rwx` | nfs.csi.k8s.io | — | TrueNAS 192.168.12.50, `/mnt/Generic_1TB/k3s_pool` |
| `longhorn-static` | driver.longhorn.io | — | legacy helper |

- Cluster-wide `default-replica-count` Setting = 1 (matches helm value); per-SC
  params override to 2.
- Longhorn v1.10.1 chart is PINNED in the role (`longhorn_chart_version`) —
  unpinning makes a re-run silently upgrade the release.
- `local-path` SC is also annotated default in the live cluster (invalid leftover);
  first apply of the storage role converges it to non-default. This is the ONLY
  intended first-apply change; after that, applies are no-op.
- Rebuilds are NOT bandwidth-throttled (`replica-rebuilding-bandwidth-limit=0`);
  rebuild time is network/disk-bound (50Gi ≈ 25 min on 1GbE).

## Deployed stack (helm releases, pinned)

| Release | Namespace | Chart / version | App |
|---|---|---|---|
| argocd | argocd | argo-cd-9.2.4 | v3.2.3 |
| cert-manager | cert-manager | v1.21.2 | v1.21.2 |
| ingress-nginx | ingress-nginx | 4.14.1 | 1.14.1 |
| metallb | metallb-system | 0.14.5 | 0.14.5 |
| longhorn | longhorn-system | 1.10.1 | v1.10.1 |
| csi-driver-nfs | kube-system | 4.12.1 | 4.12.1 |
| sealed-secrets | kube-system | 2.18.0 | 0.34.0 |

Traefik: REMOVED (deleted from kube-system; disabled in k3s config; CRDs removed).

## ArgoCD apps (source: argo-quick-apps repo)

`cloudflared`, `immich-app`, `immich-database`, `immich-storage`,
`kubernetes-dashboard`, `longhorn-dashboard`, `tandoor`.

- Immich v3.2.2: ML runs as `immich-machine-learning` (openvino variant); the
  duplicate `immich-machine-learning-cpu` deployment was deleted 2026-10-07.
- Immich redis is `redis:6.2-alpine` — candidate to move to valkey.
- Tandoor ingress issuer fixed to `internal-ca` (commit `e8baf2e` in argo-quick-apps).

## Working on this repo

- Ansible venv at `./venv` is BROKEN (built at a moved path, bad shebangs).
  Recreate locally when needed: `python3 -m venv venv && venv/bin/pip install
  ansible-core kubernetes.core jmespath` + `ansible-galaxy collection install
  ansible.posix kubernetes.core`.
- Validate changes: `ansible-playbook --syntax-check playbooks/00-k3s-server-n100.yml`
- Main playbook: `playbooks/00-k3s-server-n100.yml` (installs k3s on all servers —
  install step is skipped on nodes where `/usr/local/bin/k3s` exists — then deploys
  Longhorn + NFS storage).
- Live-cluster health check (from a machine with kubectl):
  `kubectl get nodes`, `kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded`,
  `kubectl -n longhorn-system get volumes`.
- Repo k3s.yaml kubeconfig points at the API VIP.
- etcd snapshots: daily 02:00 on n100, to NAS, retention 7, compressed.
- cert-manager self-signed root: trust `ca.crt` (repo root) on devices that need
  to trust internal TLS.

## Open items

- [ ] Watch Longhorn rebuilds complete (all 9 volumes went healthy 2026-10-07;
      re-check after the next nightly backup window)
- [ ] immich-redis: move redis 6.2 → valkey (Immich recommendation)
- [ ] `argocd-bootstrap.yaml` still has a placeholder `YOURUSERNAME` repo URL
- [ ] Consider 2.5GbE/10GbE for faster Longhorn rebuilds
