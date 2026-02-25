#!/usr/bin/env python3
"""
bm-dhcp-tap.py — DHCP ACK sniffer for BMC provisioning
=======================================================
Binds a raw AF_PACKET socket on the given interface, parses every DHCP ACK
(BOOTP op=2, option 53=5) and fires dhcp_hook2.sh for each one.

Runs entirely outside the MAAS snap; no external Python packages required.

Usage:
    python3 bm-dhcp-tap.py [INTERFACE]   # default: ens3

Environment:
    HOOK_PATH   path to dhcp_hook2.sh   (default: /opt/bm-dhcp-tap/dhcp_hook2.sh)
    LOG_FILE    log file path            (default: /opt/bm-dhcp-tap/log/dhcp-tap.log)

Deploy:
    sudo cp tools/bm-dhcp-tap.py /opt/bm-dhcp-tap/
    sudo chmod +x /opt/bm-dhcp-tap/bm-dhcp-tap.py
    sudo cp tools/bm-dhcp-tap.service /etc/systemd/system/
    sudo systemctl daemon-reload && sudo systemctl enable --now bm-dhcp-tap
"""
import logging
import os
import socket
import struct
import subprocess
import sys
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
IFACE     = (sys.argv[1] if len(sys.argv) > 1 else '') or 'ens3'
HOOK_PATH = os.environ.get('HOOK_PATH', '/opt/bm-dhcp-tap/dhcp_hook2.sh')
LOG_FILE  = os.environ.get('LOG_FILE',  '/opt/bm-dhcp-tap/log/dhcp-tap.log')

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%dT%H:%M:%SZ',
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(sys.stdout),
    ],
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# DHCP packet parser
# ---------------------------------------------------------------------------
DHCP_MAGIC = b'\x63\x82\x53\x63'

def _parse_options(payload: bytes, start: int = 240) -> dict:
    """Return {option_code: bytes} for all options in a DHCP payload."""
    opts: dict = {}
    i, n = start, len(payload)
    while i < n:
        code = payload[i]
        if code == 255:          # END
            break
        if code == 0:            # PAD
            i += 1
            continue
        if i + 1 >= n:
            break
        length = payload[i + 1]
        if i + 2 + length > n:
            break
        opts[code] = payload[i + 2: i + 2 + length]
        i += 2 + length
    return opts


def parse_dhcp_ack(frame: bytes):
    """
    Parse a raw Ethernet frame.

    Returns (ip: str, mac: str, hostname: str) when the frame is a DHCP ACK,
    or None for all other packets.
    """
    # --- Ethernet (14 bytes) ---
    if len(frame) < 14:
        return None
    ethertype = struct.unpack_from('!H', frame, 12)[0]
    if ethertype != 0x0800:          # IPv4 only
        return None

    # --- IP header ---
    ip_off = 14
    if len(frame) < ip_off + 20:
        return None
    ihl   = (frame[ip_off] & 0x0F) * 4
    proto = frame[ip_off + 9]
    if proto != 17:                  # UDP only
        return None

    # --- UDP header (8 bytes) ---
    udp_off = ip_off + ihl
    if len(frame) < udp_off + 8:
        return None
    src_port, dst_port = struct.unpack_from('!HH', frame, udp_off)
    if src_port != 67 or dst_port != 68:   # DHCP server → client
        return None

    # --- BOOTP / DHCP payload ---
    dhcp_off = udp_off + 8
    dhcp     = frame[dhcp_off:]
    if len(dhcp) < 240:
        return None

    if dhcp[0] != 2:                 # op must be BOOTREPLY
        return None

    yiaddr = socket.inet_ntoa(dhcp[16:20])             # "your" IP
    chaddr = ':'.join(f'{b:02x}' for b in dhcp[28:34]) # client MAC (first 6 bytes)

    if dhcp[236:240] != DHCP_MAGIC:
        return None

    opts = _parse_options(dhcp, 240)

    if opts.get(53, b'\x00') != b'\x05':   # option 53 = 5 → DHCP ACK
        return None

    hostname = opts[12].decode('ascii', errors='replace') if 12 in opts else 'unknown'

    return yiaddr, chaddr, hostname

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
def main() -> None:
    log.info('BM DHCP tap starting  iface=%s  hook=%s', IFACE, HOOK_PATH)

    if not os.path.isfile(HOOK_PATH):
        log.error('Hook script not found: %s — exiting', HOOK_PATH)
        sys.exit(1)

    # AF_PACKET / SOCK_RAW receives all frames before kernel routing
    # Requires CAP_NET_RAW (root or AmbientCapabilities in the systemd unit)
    with socket.socket(socket.AF_PACKET, socket.SOCK_RAW,
                       socket.htons(0x0003)) as sock:
        sock.bind((IFACE, 0))
        log.info('Listening on %s …', IFACE)

        while True:
            try:
                frame, _ = sock.recvfrom(65535)
            except KeyboardInterrupt:
                log.info('Interrupted — shutting down')
                break
            except OSError as exc:
                log.error('recvfrom error: %s', exc)
                continue

            result = parse_dhcp_ack(frame)
            if result is None:
                continue

            ip, mac, hostname = result
            log.info('DHCP ACK  IP=%-15s  MAC=%s  HOST=%s', ip, mac, hostname)

            try:
                subprocess.Popen(
                    [HOOK_PATH, ip, mac, hostname],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except OSError as exc:
                log.error('Failed to exec hook: %s', exc)


if __name__ == '__main__':
    main()
