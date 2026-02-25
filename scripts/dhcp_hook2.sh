#!/usr/bin/env bash
# =============================================================================
# DHCP Hook — Direct NetBox Integration
# =============================================================================
# Called by ISC DHCP server on every lease commit. Filters for BMC MAC OUIs,
# then updates NetBox directly via the shared FSM library.
#
# For ISC DHCP, add to /etc/dhcp/dhcpd.conf:
#
#   on commit {
#       set ClientIP   = binary-to-ascii(10, 8, ".", leased-address);
#       set ClientMac  = binary-to-ascii(16, 8, ":", substring(hardware, 1, 6));
#       set ClientHost = pick-first-value(option host-name, "unknown");
#       execute("/usr/local/bin/dhcp_hook2.sh", ClientIP, ClientMac, ClientHost);
#   }
#
# Arguments (or environment variable fallbacks):
#   $1 / LEASED_IP       IP address assigned by DHCP
#   $2 / CLIENT_MAC      Client MAC address (any separator, any case)
#   $3 / CLIENT_HOSTNAME Client hostname (optional)
#
# Environment variables: see lib/bmc-fsm.sh
#   LOG_FILE defaults to /var/log/bm/dhcp-hook.log
# =============================================================================

# Do not use set -e — dhcpd must not see a non-zero exit from this hook
set -uo pipefail

# Script-specific log file — set before sourcing the lib
LOG_FILE="${LOG_FILE:-/var/log/bm/dhcp-hook.log}"

# Load shared FSM library (NetBox helpers, OUI filter, state machine)
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bmc-fsm.sh
source "${_SCRIPT_DIR}/lib/bmc-fsm.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
IP_ADDRESS="${1:-${LEASED_IP:-}}"
MAC_ADDRESS="${2:-${CLIENT_MAC:-}}"
HOSTNAME="${3:-${CLIENT_HOSTNAME:-unknown}}"

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [[ -z "$IP_ADDRESS" || -z "$MAC_ADDRESS" ]]; then
    log_error "Missing required arguments: IP='${IP_ADDRESS}' MAC='${MAC_ADDRESS}'"
    exit 0  # exit 0 — dhcpd must not see failure
fi

# ---------------------------------------------------------------------------
# OUI filter — normalise MAC then check against known BMC vendor prefixes
# ---------------------------------------------------------------------------
MAC_NORM="$(echo "$MAC_ADDRESS" | tr '[:upper:]' '[:lower:]' | tr '-' ':')"

if ! is_bmc_mac "$MAC_NORM"; then
    exit 0  # not a BMC — ignore silently
fi

log_info "BMC DHCP lease: IP=${IP_ADDRESS} MAC=${MAC_ADDRESS} HOST=${HOSTNAME}"

# ---------------------------------------------------------------------------
# Run the FSM
# ---------------------------------------------------------------------------
fsm_process_bmc_event "dhcp_seen" "$MAC_NORM" "$IP_ADDRESS"

# Always exit 0 — dhcpd must not treat hook failure as a lease error
exit 0
