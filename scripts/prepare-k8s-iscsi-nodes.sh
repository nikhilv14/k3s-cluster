#!/usr/bin/env bash
# ============================================================
# prepare-k8s-iscsi-nodes.sh
# ============================================================
# Purpose: Idempotently prepare a k3s node (bare-metal server, VM,
# or privileged LXC container) to act as an iSCSI initiator node
# backed by TrueNAS SCALE (democratic-csi, Longhorn, etc.).
#
# Handles:
#   1. Package installation (open-iscsi, multipath-tools, lsscsi,
#      util-linux, xfsprogs, e2fsprogs).
#   2. Kernel module persistence (/etc/modules-load.d/iscsi.conf):
#      iscsi_tcp, dm_multipath, dm_snapshot.
#   3. Systemd service enablement + unmasking (iscsid, multipathd).
#   4. Mount propagation fix: ensures /var/lib/kubelet (or /) is
#      `rshared` so CSI plugins can share mounts with the kubelet.
#   5. IQN audit: prints the node initiator IQN for TrueNAS
#      initiator grouping.
#
# Idempotent: safe to run multiple times.
# ============================================================

set -euo pipefail

KUBELET_DIR="/var/lib/kubelet"
MODULES_CONF="/etc/modules-load.d/iscsi.conf"
MODULES=(iscsi_tcp dm_multipath dm_snapshot)
PACKAGES=(open-iscsi multipath-tools lsscsi util-linux xfsprogs e2fsprogs)
SERVICES=(iscsid.service multipathd.service)

# ---------------------------------------------------------
# Helpers
# ---------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo "FATAL: $*" >&2
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            die "Must run as root or have sudo available."
        fi
    fi
}

# ---------------------------------------------------------
# 1. Package installation
# ---------------------------------------------------------
install_packages() {
    log "Ensuring packages are installed: ${PACKAGES[*]}"
    local missing=()
    for pkg in "${PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1 && ! rpm -q "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log "All packages present. Skipping install."
        return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        ${SUDO} DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        ${SUDO} dnf install -y "${missing[@]}"
    elif command -v yum >/dev/null 2>&1; then
        ${SUDO} yum install -y "${missing[@]}"
    else
        die "No supported package manager found (apt/dnf/yum)."
    fi
    log "Packages installed: ${missing[*]}"
}

# ---------------------------------------------------------
# 2. Kernel module persistence + immediate load
# ---------------------------------------------------------
load_modules() {
    log "Ensuring kernel modules are loaded and persisted: ${MODULES[*]}"
    local dir
    dir=$(dirname "${MODULES_CONF}")
    ${SUDO} mkdir -p "${dir}"
    {
        echo "# Managed by prepare-k8s-iscsi-nodes.sh"
        for m in "${MODULES[@]}"; do
            echo "$m"
        done
    } | ${SUDO} tee "${MODULES_CONF}" > /dev/null

    for m in "${MODULES[@]}"; do
        if ! lsmod | grep -q "^${m} "; then
            log "Loading module: ${m}"
            ${SUDO} modprobe "$m" || die "Failed to load kernel module: ${m}"
        else
            log "Module already loaded: ${m}"
        fi
    done
}

# ---------------------------------------------------------
# 3. Systemd service enablement + unmask + start
# ---------------------------------------------------------
configure_services() {
    log "Enabling and unmasking services: ${SERVICES[*]}"
    for svc in "${SERVICES[@]}"; do
        # Unmask (idempotent — symlink removal if masked)
        if ${SUDO} systemctl is-enabled "$svc" 2>/dev/null | grep -q masked; then
            log "Unmasking ${svc}"
            ${SUDO} systemctl unmask "$svc"
        fi
        ${SUDO} systemctl daemon-reload
        ${SUDO} systemctl enable --now "$svc"
        if ! ${SUDO} systemctl is-active --quiet "$svc"; then
            die "Service failed to start: ${svc}"
        fi
        log "Service active: ${svc}"
    done
}

# ---------------------------------------------------------
# 4. Mount propagation (rshared) for kubelet dir
# ---------------------------------------------------------
fix_mount_propagation() {
    log "Ensuring ${KUBELET_DIR} (and /) are rshared for CSI."
    # Bind-mount kubelet dir onto itself to guarantee it is a distinct
    # mountpoint that we can independently set to rshared.
    ${SUDO} mkdir -p "${KUBELET_DIR}"
    if ! findmnt -n -o TARGET | grep -qx "${KUBELET_DIR}"; then
        ${SUDO} mount --bind "${KUBELET_DIR}" "${KUBELET_DIR}"
    fi

    local current
    current=$(findmnt -n -o PROPAGATION "${KUBELET_DIR}" | head -1)
    log "Current propagation for ${KUBELET_DIR}: ${current}"
    if [[ "$current" != *shared* ]]; then
        ${SUDO} mount --make-rshared "${KUBELET_DIR}"
        log "Set ${KUBELET_DIR} to rshared."
    else
        log "Propagation already shared."
    fi

    # Root propagation must also be shared for CSI to work reliably.
    local root_prop
    root_prop=$(findmnt -n -o PROPAGATION / | head -1)
    if [[ "$root_prop" != *shared* ]]; then
        log "WARNING: root propagation is '$root_prop' — make it rshared with:"
        log "  sudo mount --make-rshared /"
    fi
}

# ---------------------------------------------------------
# 4b. Persistent systemd one-shot unit (survives reboot)
# ---------------------------------------------------------
install_propagation_unit() {
    local unit_name="kubelet-propagation.service"
    local unit_path="/etc/systemd/system/${unit_name}"
    log "Installing persistent one-shot unit: ${unit_path}"
    ${SUDO} tee "${unit_path}" > /dev/null <<EOF
[Unit]
Description=Ensure kubelet dir mount propagation is rshared (CSI prerequisite)
DefaultDependencies=no
After=local-fs.target
Before=k3s.service kubelet.service containerd.service
[Service]
Type=oneshot
ExecStart=/bin/mount --bind ${KUBELET_DIR} ${KUBELET_DIR}
ExecStart=/bin/mount --make-rshared ${KUBELET_DIR}
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    ${SUDO} systemctl daemon-reload
    ${SUDO} systemctl enable --now "${unit_name}"
    log "Unit installed and enabled."
}

# ---------------------------------------------------------
# 5. Initiator IQN audit
# ---------------------------------------------------------
audit_iqn() {
    local iqn_file="/etc/iscsi/initiatorname.iscsi"
    if [[ ! -f "$iqn_file" ]]; then
        die "IQN file not found: ${iqn_file}"
    fi
    local iqn
    iqn=$(grep -E '^InitiatorName=' "$iqn_file" | head -1 | cut -d= -f2)
    if [[ -z "$iqn" ]]; then
        die "No IQN found in ${iqn_file}."
    fi
    log "Node $(hostname) IQN: ${iqn}"
}

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------
main() {
    log "Starting iSCSI node preparation on $(hostname)."
    require_root
    install_packages
    load_modules
    configure_services
    fix_mount_propagation
    install_propagation_unit
    audit_iqn
    log "Node preparation complete."
    log "NOTE: k3s-worker-z690 (LXC) is blocked from iSCSI workloads by taint"
    log "      lxc-no-iscsi=true:NoSchedule — no workloads should consume block"
    log "      storage on that node."
}

main "$@"
