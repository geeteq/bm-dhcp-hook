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
#   - BMC OUI filter     (is_bmc_mac — reads from OUI_FILE)
#   - FSM transition table + action functions
#   - fsm_process_bmc_event TRIGGER MAC IP
#
# Callers set LOG_FILE before sourcing to get script-specific log paths.
# All other vars fall back to defaults if not set in the environment.
#
# Dependencies: bash 4+, curl, jq, nc (netcat for optional syslog)
# =============================================================================

# Guard against double-sourcing
[[ -n "${_BMC_FSM_SH:-}" ]] && return 0
_BMC_FSM_SH=1

# ---------------------------------------------------------------------------
# Config defaults — override via environment or bm-dhcp-tap.cfg before sourcing
# ---------------------------------------------------------------------------
NETBOX_URL="${NETBOX_URL:-http://localhost:8000}"
NETBOX_TOKEN="${NETBOX_TOKEN:-0123456789abcdef0123456789abcdef01234567}"
BMC_SUBNET_PREFIX="${BMC_SUBNET_PREFIX:-24}"
LOG_FILE="${LOG_FILE:-/opt/bm-dhcp-tap/logs/dhcp_hook2.log}"
# Optional HTTP/HTTPS proxy for NetBox API calls
HTTPS_PROXY="${HTTPS_PROXY:-}"
# OUI file — one entry per line: xx:xx:xx,Vendor description
OUI_FILE="${OUI_FILE:-/opt/bm-dhcp-tap/etc/oui.cfg}"
# Remote syslog — leave SYSLOG_SERVER empty to disable
SYSLOG_SERVER="${SYSLOG_SERVER:-}"
SYSLOG_PORT="${SYSLOG_PORT:-514}"

mkdir -p "$(dirname "$LOG_FILE")"

# ---------------------------------------------------------------------------
# Logging
#
# Format: TIMESTAMP HOSTNAME PID LEVEL message
# Levels: DEBUG | INFORMATION | WARNING | ERROR
#
# - Always writes to stderr (visible on CLI; dhcpd discards it)
# - Always appends to LOG_FILE with 1 MB rolling rotation
# - Forwards to remote syslog if SYSLOG_SERVER is set
# ---------------------------------------------------------------------------
_LOG_MAX_BYTES=1048576   # 1 MB

_log_rotate() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ "$size" -ge "$_LOG_MAX_BYTES" ]]; then
        mv "$LOG_FILE" "${LOG_FILE}.1"
    fi
}

_syslog_send() {
    local level="$1" msg="$2"
    [[ -n "${SYSLOG_SERVER:-}" ]] || return 0
    # RFC 3164 severity: DEBUG=7 INFORMATION=6 WARNING=4 ERROR=3
    local severity
    case "$level" in
        DEBUG)       severity=7 ;;
        INFORMATION) severity=6 ;;
        WARNING)     severity=4 ;;
        ERROR)       severity=3 ;;
        *)           severity=6 ;;
    esac
    local priority=$(( (1 * 8) + severity ))   # facility 1 = user-level
    local ts; ts="$(date '+%b %d %H:%M:%S')"
    local host; host="$(hostname -s 2>/dev/null || echo localhost)"
    local tag="bm-dhcp-tap[$$]"
    printf '<%d>%s %s %s: %s\n' "$priority" "$ts" "$host" "$tag" "$msg" \
        | nc -u -w1 "$SYSLOG_SERVER" "$SYSLOG_PORT" 2>/dev/null || true
}

log() {
    local level="$1"; shift
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local host; host="$(hostname -s 2>/dev/null || echo localhost)"
    local line
    printf -v line '%s %s %d %s %s' "$ts" "$host" "$$" "$level" "$*"
    _log_rotate
    printf '%s\n' "$line" | tee -a "$LOG_FILE" >&2
    _syslog_send "$level" "$*"
}

log_debug() { log "DEBUG"       "$@"; }
log_info()  { log "INFORMATION" "$@"; }
log_warn()  { log "WARNING"     "$@"; }
log_error() { log "ERROR"       "$@"; }

# ---------------------------------------------------------------------------
# BMC OUI filter — reads from OUI_FILE (no hardcoded prefixes)
#
# is_bmc_mac LOWER_COLON_MAC — returns 0 if OUI matches, 1 otherwise
# ---------------------------------------------------------------------------
is_bmc_mac() {
    local oui="${1:0:8}"
    if [[ ! -f "$OUI_FILE" ]]; then
        log_warn "OUI file not found: ${OUI_FILE} — all MACs will be rejected"
        return 1
    fi
    while IFS=, read -r prefix _vendor || [[ -n "$prefix" ]]; do
        # skip blank lines and comments
        [[ -z "$prefix" || "${prefix:0:1}" == "#" ]] && continue
        # normalise entry to lowercase
        local norm_prefix; norm_prefix="$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')"
        [[ "$oui" == "$norm_prefix" ]] && return 0
    done < "$OUI_FILE"
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
    [[ -n "${HTTPS_PROXY:-}" ]] && curl_args+=(--proxy "$HTTPS_PROXY")
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
    [[ -n "${HTTPS_PROXY:-}" ]] && curl_args+=(--proxy "$HTTPS_PROXY")
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
