#!/usr/bin/env bash
# =============================================================================
# netbox_load_bmc_mac.sh — Bulk-load BMC MAC addresses into NetBox
# =============================================================================
# Reads a CSV of server serial numbers + BMC MAC addresses and for each row:
#   1. Looks up the device in NetBox by serial number (fails if not found)
#   2. Finds the BMC interface (name: bmc, ilo, idrac — any case)
#   3. If the interface already has a DIFFERENT MAC: journal an error, skip
#   4. If the interface has no MAC: set it from the CSV, journal success
#
# Usage:
#   ./netbox_load_bmc_mac.sh <input.csv>
#
# CSV format (header required):
#   server_serial,server_bmc_mac
#   MXP1111111,A0:36:9F:7C:05:00
#
# Environment: see lib/bmc-fsm.sh
#   LOG_FILE defaults to /opt/bm-dhcp-tap/log/netbox-load-bmc-mac.log
# =============================================================================

set -uo pipefail

LOG_FILE="${LOG_FILE:-/opt/bm-dhcp-tap/log/netbox-load-bmc-mac.log}"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/bmc-fsm.sh
source "${_SCRIPT_DIR}/../lib/bmc-fsm.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
CSV_FILE="${1:-}"

if [[ -z "$CSV_FILE" ]]; then
    log_error "Usage: $0 <input.csv>"
    exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
    log_error "Input file not found: $CSV_FILE"
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# norm_mac MAC — normalise to uppercase colon-separated (NetBox storage format)
norm_mac() {
    echo "$1" | tr '[:lower:]' '[:upper:]' | tr '-' ':'
}

# find_device_by_serial SERIAL
# Prints the first matching device JSON object, returns 1 if not found.
find_device_by_serial() {
    local serial="$1"
    local resp
    resp="$(nb_get "/api/dcim/devices/?serial=${serial}")" || return 1

    local count; count="$(echo "$resp" | jq -r '.count')"
    if [[ "$count" == "0" || -z "$count" ]]; then
        log_error "Device not found in NetBox for serial: ${serial}"
        return 1
    fi

    echo "$resp" | jq '.results[0]'
}

# find_bmc_interface DEVICE_ID
# Searches all interfaces on the device for a name matching bmc, ilo, or idrac
# (case-insensitive). Prints the interface JSON object, returns 1 if not found.
find_bmc_interface() {
    local device_id="$1"
    local resp
    resp="$(nb_get "/api/dcim/interfaces/?device_id=${device_id}&limit=50")" || return 1

    local iface
    iface="$(echo "$resp" | jq '
        [ .results[]
          | select(.name | ascii_downcase | test("^(bmc|ilo|idrac)$")) ]
        | .[0] // empty')"

    if [[ -z "$iface" || "$iface" == "null" ]]; then
        log_error "No BMC interface (bmc / ilo / idrac) found on device ID ${device_id}"
        return 1
    fi

    echo "$iface"
}

# ---------------------------------------------------------------------------
# Main loop — process substitution keeps ok/failed counters in this shell
# ---------------------------------------------------------------------------
ok=0
failed=0

while IFS=, read -r serial mac_raw _rest; do
    # Strip carriage returns and surrounding whitespace
    serial="$(echo "$serial"  | tr -d '\r' | xargs)"
    mac_raw="$(echo "$mac_raw" | tr -d '\r' | xargs)"

    [[ -z "$serial" || -z "$mac_raw" ]] && continue

    mac="$(norm_mac "$mac_raw")"
    log_info "Processing  serial=${serial}  mac=${mac}"

    # 1 — Look up device by serial
    device_json="$(find_device_by_serial "$serial")" || { ((failed++)); continue; }
    device_id="$(  echo "$device_json" | jq -r '.id')"
    device_name="$(echo "$device_json" | jq -r '.name')"
    log_info "  Device: ${device_name} (id=${device_id})"

    # 2 — Find BMC interface (bmc / ilo / idrac, any case)
    iface_json="$(find_bmc_interface "$device_id")" || { ((failed++)); continue; }
    iface_id="$(   echo "$iface_json" | jq -r '.id')"
    iface_name="$( echo "$iface_json" | jq -r '.name')"
    current_mac="$(echo "$iface_json" | jq -r '.mac_address // empty')"
    log_info "  Interface: ${iface_name} (id=${iface_id})  current_mac='${current_mac:-<none>}'"

    # 3 — Interface already has a MAC — compare
    if [[ -n "$current_mac" ]]; then
        current_mac_norm="$(norm_mac "$current_mac")"
        if [[ "$current_mac_norm" != "$mac" ]]; then
            log_error "  MAC mismatch on ${device_name}/${iface_name}: NetBox=${current_mac_norm}  CSV=${mac} — skipping"
            nb_journal "$device_id" \
                "BMC MAC import conflict on interface '${iface_name}': existing MAC ${current_mac_norm} differs from import value ${mac} — no change made" \
                "warning"
            ((failed++))
            continue
        fi
        log_info "  MAC ${mac} already set correctly — nothing to do"
        ((ok++))
        continue
    fi

    # 4 — No MAC on interface — set it from the CSV
    nb_patch "/api/dcim/interfaces/${iface_id}/" \
        "{\"mac_address\": \"${mac}\"}" > /dev/null || {
        log_error "  Failed to patch interface ${iface_id} with MAC ${mac}"
        ((failed++))
        continue
    }
    log_info "  MAC ${mac} written to ${device_name}/${iface_name}"
    nb_journal "$device_id" \
        "BMC MAC address set on interface '${iface_name}': ${mac}" \
        "success"
    ((ok++))

done < <(tail -n +2 "$CSV_FILE")

log_info "Finished — ok=${ok}  failed=${failed}"
[[ "$failed" -eq 0 ]]
