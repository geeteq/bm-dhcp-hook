#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Install bm-dhcp-tap on a MAAS rack controller (Ubuntu)
# =============================================================================
# Run from the repository root:
#   sudo bash scripts/tools/deploy.sh [--iface IFACE]
#
# Options:
#   --iface IFACE   Network interface to sniff (default: ens3)
#
# What this script does:
#   1. Checks prerequisites (root, Ubuntu, python3, curl, jq)
#   2. Creates /opt/bm-dhcp-tap/{etc,scripts,scripts/lib,logs,doc}/
#   3. Installs scripts and sets permissions
#   4. Creates /opt/bm-dhcp-tap/etc/bm-dhcp-tap.cfg if it does not exist
#      (existing file is NOT overwritten — credentials are preserved)
#   5. Writes/updates IFACE in bm-dhcp-tap.cfg
#   6. Installs /opt/bm-dhcp-tap/etc/oui.cfg (OUI vendor list)
#   7. Installs and starts the systemd service
#
# Idempotent — safe to re-run after upgrades.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
IFACE="ens3"
INSTALL_DIR="/opt/bm-dhcp-tap"
SERVICE_NAME="bm-dhcp-tap"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# Resolve repo root (two levels up from this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iface)
            IFACE="$2"; shift 2 ;;
        --iface=*)
            IFACE="${1#--iface=}"; shift ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: sudo bash scripts/tools/deploy.sh [--iface IFACE]" >&2
            exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf '\e[32m[INFO]\e[0m  %s\n' "$*"; }
warn()  { printf '\e[33m[WARN]\e[0m  %s\n' "$*"; }
error() { printf '\e[31m[ERROR]\e[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 1 — Preflight checks
# ---------------------------------------------------------------------------
info "=== bm-dhcp-tap deploy ==="

[[ "$(id -u)" -eq 0 ]] || die "Must be run as root: sudo bash scripts/tools/deploy.sh"

# Ubuntu check
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || warn "OS is '${ID:-unknown}', not Ubuntu — proceeding anyway"
    info "OS: ${PRETTY_NAME:-Ubuntu}"
else
    warn "/etc/os-release not found — skipping OS check"
fi

# Dependency checks
for dep in python3 curl jq nc; do
    if ! command -v "$dep" &>/dev/null; then
        die "Required dependency not found: ${dep}  (install with: apt-get install -y ${dep})"
    fi
    info "Dependency OK: $(command -v "$dep")"
done

info "Interface: ${IFACE}"

# Verify the interface exists on this host
if ! ip link show "$IFACE" &>/dev/null; then
    warn "Interface '${IFACE}' not found on this host — service will fail to start until it exists"
fi

# ---------------------------------------------------------------------------
# 2 — Create directory structure
# ---------------------------------------------------------------------------
info "Creating ${INSTALL_DIR}/{etc,scripts,scripts/lib,logs,doc}/"
mkdir -p "${INSTALL_DIR}/etc"
mkdir -p "${INSTALL_DIR}/scripts/lib"
mkdir -p "${INSTALL_DIR}/logs"
mkdir -p "${INSTALL_DIR}/doc"
chmod 750 "${INSTALL_DIR}"
chmod 750 "${INSTALL_DIR}/logs"

# ---------------------------------------------------------------------------
# 3 — Install scripts
# ---------------------------------------------------------------------------
info "Installing scripts to ${INSTALL_DIR}/scripts/"

install -m 755 "${REPO_ROOT}/scripts/dhcp_hook2.sh"        "${INSTALL_DIR}/scripts/dhcp_hook2.sh"
install -m 644 "${REPO_ROOT}/scripts/lib/bmc-fsm.sh"       "${INSTALL_DIR}/scripts/lib/bmc-fsm.sh"
install -m 755 "${REPO_ROOT}/scripts/tools/bm-dhcp-tap.py" "${INSTALL_DIR}/scripts/bm-dhcp-tap.py"

info "Installed:"
info "  ${INSTALL_DIR}/scripts/dhcp_hook2.sh"
info "  ${INSTALL_DIR}/scripts/lib/bmc-fsm.sh"
info "  ${INSTALL_DIR}/scripts/bm-dhcp-tap.py"

# ---------------------------------------------------------------------------
# 4 — Install OUI config (always updated to pick up new vendor additions)
# ---------------------------------------------------------------------------
info "Installing OUI list to ${INSTALL_DIR}/etc/oui.cfg"
install -m 644 "${REPO_ROOT}/scripts/tools/oui.cfg" "${INSTALL_DIR}/etc/oui.cfg"

# ---------------------------------------------------------------------------
# 5 — Create bm-dhcp-tap.cfg (if it does not exist)
# ---------------------------------------------------------------------------
CFG_FILE="${INSTALL_DIR}/etc/bm-dhcp-tap.cfg"

if [[ ! -f "$CFG_FILE" ]]; then
    info "Creating ${CFG_FILE} (template — fill in NETBOX_URL and NETBOX_TOKEN)"
    cat > "$CFG_FILE" <<EOF
# bm-dhcp-tap configuration
# Edit before starting the service. Permissions: 640 (root:root)

# ── NetBox ──────────────────────────────────────────────────────────────────
NETBOX_URL=https://your-netbox
NETBOX_TOKEN=your-token-here

# Optional proxy for NetBox API calls (leave empty to connect directly)
# HTTPS_PROXY=http://proxy.corp.example.com:3128

# ── Network ─────────────────────────────────────────────────────────────────
# Network interface for DHCP snooping — updated by deploy.sh
IFACE=${IFACE}
BMC_SUBNET_PREFIX=24

# ── OUI filter ──────────────────────────────────────────────────────────────
OUI_FILE=/opt/bm-dhcp-tap/etc/oui.cfg

# ── Syslog (optional) ───────────────────────────────────────────────────────
# Leave SYSLOG_SERVER empty to disable remote syslog streaming.
# When set, all log messages are forwarded via UDP (RFC 3164).
SYSLOG_SERVER=
SYSLOG_PORT=514
EOF
    chmod 640 "$CFG_FILE"
    warn "IMPORTANT: edit ${CFG_FILE} and set NETBOX_URL + NETBOX_TOKEN before the service can work"
else
    info "${CFG_FILE} already exists — credentials preserved"
    # Update IFACE in the existing file
    if grep -q "^IFACE=" "$CFG_FILE"; then
        sed -i "s|^IFACE=.*|IFACE=${IFACE}|" "$CFG_FILE"
        info "Updated IFACE=${IFACE} in ${CFG_FILE}"
    else
        echo "IFACE=${IFACE}" >> "$CFG_FILE"
        info "Appended IFACE=${IFACE} to ${CFG_FILE}"
    fi
fi

# ---------------------------------------------------------------------------
# 6 — Install systemd service
# ---------------------------------------------------------------------------
info "Installing ${SERVICE_FILE}"
install -m 644 "${REPO_ROOT}/scripts/tools/bm-dhcp-tap.service" "$SERVICE_FILE"

info "Reloading systemd daemon"
systemctl daemon-reload

info "Enabling ${SERVICE_NAME}"
systemctl enable "$SERVICE_NAME"

# Start or restart
if systemctl is-active --quiet "$SERVICE_NAME"; then
    info "Restarting ${SERVICE_NAME}"
    systemctl restart "$SERVICE_NAME"
else
    info "Starting ${SERVICE_NAME}"
    systemctl start "$SERVICE_NAME"
fi

# ---------------------------------------------------------------------------
# 7 — Status
# ---------------------------------------------------------------------------
echo ""
systemctl status "$SERVICE_NAME" --no-pager --lines=10 || true

echo ""
info "=== Deploy complete ==="
info "Logs:    journalctl -fu ${SERVICE_NAME}"
info "Logfile: ${INSTALL_DIR}/logs/bm-dhcp-tap.log"
info "Logfile: ${INSTALL_DIR}/logs/dhcp_hook2.log"
[[ -f "$CFG_FILE" ]] && grep -q "your-token-here" "$CFG_FILE" && \
    warn "Remember to set NETBOX_URL and NETBOX_TOKEN in ${CFG_FILE} then: systemctl restart ${SERVICE_NAME}"
