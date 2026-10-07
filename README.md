# k3sSetup

Ansible-based provisioning and declarative configuration for a **3-node HA k3s
homelab cluster** running on Proxmox, with Longhorn distributed storage and an
ingress stack fronted by MetalLB.

> For AI agents / deep context, see [AGENTS.md](AGENTS.md).
> Current architecture status lives in [PROJECT_CONTEXT_COMPLETE.md](PROJECT_CONTEXT_COMPLETE.md).

## Architecture

```
                    kube-apiserver VIP: 192.168.12.10:6443  (kube-vip, ARP)
                    ingress VIP:        192.168.12.61       (MetalLB → ingress-nginx)
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │ k3s-node1 / n100         │ k3s-server-nuc           │ k3s-server-hp-g9   │
        │ 192.168.12.51            │ 192.168.12.110           │ 192.168.12.132     │
        │ control-plane + etcd     │ control-plane + etcd     │ control-plane + etcd│
        │ always-on, NAS snapshots │ Proxmox VM               │ Proxmox VM         │
        └──────────────────────────┴──────────────────────────┴────────────────────┘
```

- **k3s** `v1.36.5+k3s1` with embedded etcd, flannel vxlan (UDP 8472, all nodes standard)
- **traefik + klipper servicelb disabled** in k3s config — ingress-nginx + MetalLB instead
- **kube-vip** fronts the API server; kubeconfig and node joins use the VIP
- **ArgoCD** (v3.2.3) deploys all apps from [argo-quick-apps](https://github.com/nikhilv14/argo-quick-apps):
  immich, tandoor, cloudflared, kubernetes-dashboard

## Storage

| StorageClass | Provisioner | Replicas | Purpose |
|---|---|---|---|
| `longhorn` | Longhorn | 2 | default block storage |
| `ssd-cache` | Longhorn | 2 | requires `ssd` node/disk tags, best-effort locality |
| `nas-rwx` | nfs.csi.k8s.io | — | TrueNAS NFS RWX (`192.168.12.50:/mnt/Generic_1TB/k3s_pool`) |

Longhorn chart is pinned (`1.10.1`) so re-runs never silently upgrade.

## Repo layout

```
inventory/          hosts + group_vars/host_vars (servers, storage, localhost)
playbooks/          00-k3s-server-n100.yml  (install k3s on servers + storage roles)
roles/
  k3s_server/       k3s install, config.yaml rendering, node labels
  storage_longhorn/ Longhorn helm install (pinned), node labels + 'ssd' tags
  storage_nfs/      NFS CSI StorageClass + test PV/PVC
networking/         deploy.sh (MetalLB, ingress-nginx, cert-manager, kube-vip, issuers)
storage_setup/      Longhorn settings + storage classes
argocd/             ArgoCD helm values + ingress
```

## Quick start

```bash
# 1. prerequisites
python3 -m venv venv
venv/bin/pip install ansible-core kubernetes jmespath pyyaml
venv/bin/ansible-galaxy collection install ansible.posix kubernetes.core

# 2. join token (untracked)
echo "<k3s join token>" > inventory/group_vars/k3s_token.secret

# 3. provision / converge (no-op if cluster already matches)
venv/bin/ansible-playbook playbooks/00-k3s-server-n100.yml

# 4. networking stack (idempotent, pinned versions)
./networking/deploy.sh
```

The fetched kubeconfig (`./k3s.yaml`, gitignored) is rewritten to point at the
API VIP. Copy it or `export KUBECONFIG=$(pwd)/k3s.yaml`.

## Secrets policy

Nothing sensitive is committed. `.gitignore` excludes the kubeconfig (`k3s.yaml`),
certs/keys (`*.crt`, `*.key`, `*.pem`, `ca.crt`) and the join token
(`k3s_token.secret`, `*.secret`). Internal TLS certs are issued by the
`internal-ca` cert-manager issuer (self-signed root — trust `ca.crt` on devices).

## Operation notes

- Adding a **new server node**: see the Longhorn onboarding checklist in
  [AGENTS.md](AGENTS.md) (iscsi/nfs packages, node labels, `ssd` tags).
- etcd snapshots: daily 02:00 on k3s-node1 → NAS, retention 7, compressed.
- Do **not** reintroduce the old custom flannel UDP port 48472
  (`flannel-net-conf.json`); a port mismatch between nodes breaks the overlay
  network. All nodes are on the default 8472.
