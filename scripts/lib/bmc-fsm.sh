#!/usr/bin/env bash
# =============================================================================
# BMC Discovery — Shared FSM Library
# =============================================================================
# Source this file; do not execute it directly.
#
# Provides:
#   - NetBox API helpers (nb_curl, nb_get, nb_post, nb_patch)
#   - NetBox operations  (nb_find_device_by_bmc_mac, nb_update_device_state,
#                         nb_assign_ip, nb_update_bmc_ip, nb_journal)
#   - BMC OUI filter     (BMC_OUIS array, is_bmc_mac)
#   - FSM transition table + action functions
#   - fsm_process_bmc_event TRIGGER MAC IP
#
# Callers set LOG_FILE before sourcing to get script-specific log paths.
# All other vars fall back to defaults if not set in the environment.
#
# Dependencies: bash 4+, curl, jq
# =============================================================================

# Guard against double-sourcing
[[ -n "${_BMC_FSM_SH:-}" ]] && return 0
_BMC_FSM_SH=1

# ---------------------------------------------------------------------------
# Config defaults — override by setting in environment before sourcing
# ---------------------------------------------------------------------------
NETBOX_URL="${NETBOX_URL:-http://localhost:8000}"
NETBOX_TOKEN="${NETBOX_TOKEN:-0123456789abcdef0123456789abcdef01234567}"
BMC_SUBNET_PREFIX="${BMC_SUBNET_PREFIX:-24}"
LOG_FILE="${LOG_FILE:-/var/log/bm/bmc.log}"

mkdir -p "$(dirname "$LOG_FILE")"

# ---------------------------------------------------------------------------
# Logging — always writes to stderr + log file so stdout stays clean
# for command substitutions ($(...))
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s [%s] %s\n' "$ts" "$level" "$*" | tee -a "$LOG_FILE" >&2
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# BMC OUI filter
# Add / remove vendor OUI prefixes (lower-case, colon-separated, 3 octets)
# ---------------------------------------------------------------------------
BMC_OUIS=(
    "a0:36:9f"   # HPE iLO (ProLiant)
    "d0:67:e5"   # Dell iDRAC
    "3c:a8:2a"   # Dell iDRAC (newer gen)
    "14:18:77"   # Supermicro IPMI
    "18:fb:7b"   # Supermicro IPMI
    "b4:96:91"   # Lenovo XClarity (XCC)
    "d0:94:66"   # Cisco CIMC
)

# is_bmc_mac LOWER_COLON_MAC — returns 0 if OUI matches, 1 otherwise
is_bmc_mac() {
    local oui="${1:0:8}"
    for prefix in "${BMC_OUIS[@]}"; do
        [[ "$oui" == "$prefix" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# NetBox API helpers — all requests timeout after 20 seconds
#
# nb_curl METHOD PATH [BODY]
#   Prints response body on 2xx. Returns 1 and logs on any error.
#
# nb_curl_raw METHOD PATH [BODY]
#   Prints response body + HTTP status code as the final line.
#   Use when the caller needs to inspect specific codes (e.g. 400).
# ---------------------------------------------------------------------------
nb_curl() {
    local method="$1" path="$2" body="${3:-}"
    local tmp; tmp="$(mktemp)"
    local curl_args=(
        --silent --show-error
        --max-time 20
        -X "$method"
        -H "Authorization: Token ${NETBOX_TOKEN}"
        -H "Content-Type: application/json"
        -H "Accept: application/json"
        -o "$tmp"
        -w '%{http_code}'
    )
    [[ -n "$body" ]] && curl_args+=(--data-raw "$body")

    local http_code
    http_code="$(curl "${curl_args[@]}" "${NETBOX_URL%/}${path}")" || {
        rm -f "$tmp"
        log_error "curl transport error: ${method} ${path}"
        return 1
    }

    local resp; resp="$(cat "$tmp")"; rm -f "$tmp"

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$resp"
        return 0
    fi

    log_error "NetBox ${method} ${path} => HTTP ${http_code}: ${resp}"
    return 1
}

nb_curl_raw() {
    local method="$1" path="$2" body="${3:-}"
    local tmp; tmp="$(mktemp)"
    local curl_args=(
        --silent --show-error
        --max-time 20
        -X "$method"
        -H "Authorization: Token ${NETBOX_TOKEN}"
        -H "Content-Type: application/json"
        -H "Accept: application/json"
        -o "$tmp"
        -w '%{http_code}'
    )
    [[ -n "$body" ]] && curl_args+=(--data-raw "$body")

    local http_code
    http_code="$(curl "${curl_args[@]}" "${NETBOX_URL%/}${path}")" || {
        rm -f "$tmp"
        log_error "curl transport error: ${method} ${path}"
        return 1
    }

    cat "$tmp"; rm -f "$tmp"
    printf '\n%s\n' "$http_code"
}

nb_get()   { nb_curl GET   "$1";      }
nb_post()  { nb_curl POST  "$1" "$2"; }
nb_patch() { nb_curl PATCH "$1" "$2"; }

# ---------------------------------------------------------------------------
# NetBox operations
# ---------------------------------------------------------------------------

# nb_find_device_by_bmc_mac MAC
# Prints JSON: {device_id, device_name, interface_id, current_state}
# Returns 1 if not found or on API error.
nb_find_device_by_bmc_mac() {
    local mac; mac="$(echo "$1" | tr '[:lower:]' '[:upper:]' | tr '-' ':')"

    log_info "Looking up NetBox device for MAC: ${mac}"

    local iface_resp
    iface_resp="$(nb_get "/api/dcim/interfaces/?mac_address=${mac}")" || return 1

    local count; count="$(echo "$iface_resp" | jq -r '.count')"
    if [[ "$count" == "0" || -z "$count" ]]; then
        log_warn "No device found in NetBox for MAC ${mac}"
        return 1
    fi

    local iface_id device_id
    iface_id="$(echo  "$iface_resp" | jq -r '.results[0].id')"
    device_id="$(echo "$iface_resp" | jq -r '.results[0].device.id')"

    local dev_resp
    dev_resp="$(nb_get "/api/dcim/devices/${device_id}/")" || return 1

    local device_name current_state
    device_name="$(echo   "$dev_resp" | jq -r '.name')"
    current_state="$(echo "$dev_resp" | jq -r '.status.value')"

    log_info "Found: ${device_name} (ID: ${device_id}) state=${current_state}"

    jq -n \
        --argjson device_id     "$device_id" \
        --arg     device_name   "$device_name" \
        --argjson interface_id  "$iface_id" \
        --arg     current_state "$current_state" \
        '{device_id:$device_id, device_name:$device_name,
          interface_id:$interface_id, current_state:$current_state}'
}

nb_update_device_state() {
    local device_id="$1" new_state="$2"
    nb_patch "/api/dcim/devices/${device_id}/" \
        "{\"status\": \"${new_state}\"}" > /dev/null || return 1
    log_info "Device ${device_id} state → ${new_state}"
}

# nb_assign_ip INTERFACE_ID IP — tolerates 400 (duplicate IP) as a warning
nb_assign_ip() {
    local iface_id="$1" ip="$2"
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local body
    body="$(jq -n \
        --arg     address "${ip}/${BMC_SUBNET_PREFIX}" \
        --argjson obj_id  "$iface_id" \
        --arg     desc    "Auto-assigned by DHCP on ${ts}" \
        '{address:$address, assigned_object_type:"dcim.interface",
          assigned_object_id:$obj_id, status:"active", description:$desc}')"

    local output; output="$(nb_curl_raw POST "/api/ipam/ip-addresses/" "$body")" || return 1
    local http_code; http_code="$(echo "$output" | tail -1)"

    case "$http_code" in
        201) log_info "IP ${ip} assigned to interface ${iface_id}" ;;
        400)
            log_warn "IP ${ip} already exists — looking up to assign to interface ${iface_id}"
            local existing
            existing="$(nb_get "/api/ipam/ip-addresses/?address=${ip}%2F${BMC_SUBNET_PREFIX}")" || {
                log_error "Could not look up existing IP ${ip}"; return 1
            }
            local ip_id; ip_id="$(echo "$existing" | jq -r '.results[0].id // empty')"
            if [[ -z "$ip_id" ]]; then
                log_error "IP ${ip} not found after 400 — cannot assign"; return 1
            fi
            local patch_body
            patch_body="$(jq -n \
                --argjson obj_id "$iface_id" \
                '{assigned_object_type:"dcim.interface", assigned_object_id:$obj_id, status:"active"}')"
            nb_patch "/api/ipam/ip-addresses/${ip_id}/" "$patch_body" > /dev/null || return 1
            log_info "Existing IP ${ip} (id=${ip_id}) assigned to interface ${iface_id}"
            ;;
        *)   log_error "Failed to assign IP ${ip}: HTTP ${http_code}"; return 1 ;;
    esac
}

# nb_update_bmc_ip INTERFACE_ID IP — ensures IP is assigned to interface
nb_update_bmc_ip() {
    local iface_id="$1" ip="$2"

    # Check if the correct IP is already assigned to this interface
    local check
    check="$(nb_get "/api/ipam/ip-addresses/?address=${ip}%2F${BMC_SUBNET_PREFIX}&interface_id=${iface_id}")" || {
        log_warn "Could not query IPs for interface ${iface_id} — falling back to assign"
        nb_assign_ip "$iface_id" "$ip"
        return
    }

    local count; count="$(echo "$check" | jq -r '.count')"
    if [[ "$count" != "0" && -n "$count" ]]; then
        log_info "BMC IP ${ip} already assigned to interface ${iface_id} — no update needed"
        return 0
    fi

    # Not assigned yet — nb_assign_ip handles both new creation and existing-IP reassignment
    nb_assign_ip "$iface_id" "$ip"
}

# nb_journal DEVICE_ID MESSAGE KIND  (journal failure is always non-fatal)
nb_journal() {
    local device_id="$1" message="$2" kind="${3:-info}"
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local body
    body="$(jq -n \
        --argjson device_id "$device_id" \
        --arg     kind      "$kind" \
        --arg     comments  "[${ts}] ${message}" \
        '{assigned_object_type:"dcim.device", assigned_object_id:$device_id,
          kind:$kind, comments:$comments}')"

    local output
    output="$(nb_curl_raw POST "/api/extras/journal-entries/" "$body")" || {
        log_warn "Journal entry failed (non-fatal): ${message}"
        return 0
    }
    local http_code; http_code="$(echo "$output" | tail -1)"
    [[ "$http_code" == "201" ]] || log_warn "Journal HTTP ${http_code} for device ${device_id}"
    return 0
}

# =============================================================================
# FSM — Transition table and action functions
# =============================================================================
#
# Each action function signature:
#   _fsm_<name> device_id device_name interface_id ip_address mac_address
#
# Transition table format: "trigger:from_state:to_state:action_function"
#
# To add a new lifecycle stage:
#   1. Write a _fsm_<name>() action function below
#   2. Add a row to FSM_TRANSITIONS
#   3. Update docs/bmc-flow.dot
# =============================================================================

# ---------------------------------------------------------------------------
# Action functions
# ---------------------------------------------------------------------------

# offline → discovered: first time this BMC has been seen on the network
_fsm_offline_to_discovered() {
    local device_id="$1" device_name="$2" interface_id="$3" ip="$4" mac="$5"
    nb_update_device_state "$device_id" "discovered" || return 1
    nb_journal "$device_id" "Lifecycle state changed: offline -> discovered" "success"
    nb_assign_ip "$interface_id" "$ip"
    nb_journal "$device_id" "IP address ${ip} assigned to interface bmc" "info"
    log_info "FSM: ${device_name} offline -> discovered"
}

# discovered → discovered: DHCP renewal; device not yet staged
_fsm_discovered_refresh() {
    local device_id="$1" device_name="$2" interface_id="$3" ip="$4" mac="$5"
    nb_assign_ip "$interface_id" "$ip"
    nb_journal "$device_id" "IP address ${ip} assigned to interface bmc" "info"
    log_info "FSM: ${device_name} already discovered — IP refreshed"
}

# active → active: live tenant device; check DHCP IP against NetBox record, journal mismatch
_fsm_active_refresh() {
    local device_id="$1" device_name="$2" interface_id="$3" ip="$4" mac="$5"

    local ip_resp
    ip_resp="$(nb_get "/api/ipam/ip-addresses/?interface_id=${interface_id}&limit=1")" || {
        log_warn "FSM: ${device_name} — could not query BMC IP from NetBox"
        return 0
    }

    local count; count="$(echo "$ip_resp" | jq -r '.count')"
    if [[ "$count" == "0" || -z "$count" ]]; then
        log_info "FSM: ${device_name} is active — no IP on record, assigning ${ip}"
        nb_assign_ip "$interface_id" "$ip"
        nb_journal "$device_id" "BMC IP ${ip} assigned to interface bmc (none was on record)" "info"
        return 0
    fi

    local recorded_ip; recorded_ip="$(echo "$ip_resp" | jq -r '.results[0].address' | cut -d/ -f1)"
    if [[ "$recorded_ip" != "$ip" ]]; then
        log_warn "FSM: ${device_name} IP mismatch — NetBox has ${recorded_ip}, DHCP offered ${ip}"
        nb_journal "$device_id" \
            "BMC IP mismatch: NetBox record=${recorded_ip}, DHCP offered=${ip}" "warning"
    else
        log_info "FSM: ${device_name} is active — BMC IP ${ip} matches NetBox record"
    fi
}

# Stub actions for future stages — implement and uncomment table rows below
# _fsm_discovered_to_staged()  { ... }  # after PXE / LLDP validation
# _fsm_staged_to_ready()       { ... }  # after vendor provisioning + firmware
# _fsm_ready_to_active()       { ... }  # after tenant delivery
# _fsm_active_to_decommissioned() { ... }

# ---------------------------------------------------------------------------
# Transition table
# Format: "trigger:from_state:to_state:action_function"
# ---------------------------------------------------------------------------
FSM_TRANSITIONS=(
    "dhcp_seen:offline:discovered:_fsm_offline_to_discovered"
    "dhcp_seen:discovered:discovered:_fsm_discovered_refresh"
    "dhcp_seen:active:active:_fsm_active_refresh"

    # Uncomment as you build out each lifecycle stage:
    # "pxe_complete:discovered:staged:_fsm_discovered_to_staged"
    # "provisioned:staged:ready:_fsm_staged_to_ready"
    # "delivered:ready:active:_fsm_ready_to_active"
    # "decommission:active:decommissioned:_fsm_active_to_decommissioned"
)

# ---------------------------------------------------------------------------
# fsm_process_bmc_event TRIGGER MAC IP
#
# Looks up the device, fires the discovery journal entry, then dispatches
# to the matching action function. Logs a warning and journals if no
# transition matches the current state.
# ---------------------------------------------------------------------------
fsm_process_bmc_event() {
    local trigger="$1" mac="$2" ip="$3"

    local device_info
    if ! device_info="$(nb_find_device_by_bmc_mac "$mac")"; then
        log_error "FSM: device not found for MAC ${mac} — no action taken"
        return 1
    fi

    local device_id device_name interface_id current_state
    device_id="$(echo     "$device_info" | jq -r '.device_id')"
    device_name="$(echo   "$device_info" | jq -r '.device_name')"
    interface_id="$(echo  "$device_info" | jq -r '.interface_id')"
    current_state="$(echo "$device_info" | jq -r '.current_state')"

    # Audit trail — always written regardless of state
    nb_journal "$device_id" \
        "BMC discovered via DHCP - MAC: ${mac}, IP: ${ip}" "success"

    # Dispatch to the matching transition
    local matched=false
    for row in "${FSM_TRANSITIONS[@]}"; do
        local t from to action
        IFS=: read -r t from to action <<< "$row"
        if [[ "$t" == "$trigger" && "$from" == "$current_state" ]]; then
            log_info "FSM: [${current_state}] --${trigger}--> [${to}]  (${device_name})"
            "$action" "$device_id" "$device_name" "$interface_id" "$ip" "$mac"
            log_info "FSM: ${device_name} done"
            matched=true
            break
        fi
    done

    if ! $matched; then
        log_warn "FSM: no transition for trigger='${trigger}' state='${current_state}' on ${device_name}"
        nb_journal "$device_id" \
            "BMC event '${trigger}' has no transition from state '${current_state}'" "warning"
    fi
}
