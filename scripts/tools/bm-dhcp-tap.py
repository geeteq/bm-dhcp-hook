#!/usr/bin/env python3
"""
bm-dhcp-tap.py — DHCP ACK sniffer for BMC provisioning
=======================================================
Binds a raw AF_PACKET socket on the given interface, parses every DHCP ACK
(BOOTP op=2, option 53=5) and fires dhcp_hook2.sh for each one.

Runs entirely outside the MAAS snap; no external Python packages required.

Usage:
    python3 bm-dhcp-tap.py [INTERFACE]   # default: ens3

Config (loaded from /opt/bm-dhcp-tap/etc/bm-dhcp-tap.cfg, then env overrides):
    IFACE           Network interface to sniff   (default: ens3)
    HOOK_PATH       Path to dhcp_hook2.sh        (default: /opt/bm-dhcp-tap/scripts/dhcp_hook2.sh)
    LOG_FILE        Log file path                (default: /opt/bm-dhcp-tap/logs/bm-dhcp-tap.log)
    SYSLOG_SERVER   Remote syslog host           (default: empty = disabled)
    SYSLOG_PORT     Remote syslog UDP port       (default: 514)

Deploy:
    sudo bash scripts/tools/deploy.sh [--iface IFACE]
"""
import logging
import logging.handlers
import os
import socket
import struct
import subprocess
import sys
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Config loader — reads /opt/bm-dhcp-tap/etc/bm-dhcp-tap.cfg
# Env vars already set take precedence (systemd EnvironmentFile wins).
# ---------------------------------------------------------------------------
_CONFIG_FILE = os.environ.get('BM_CONFIG', '/opt/bm-dhcp-tap/etc/bm-dhcp-tap.cfg')

def _load_config(path: str) -> None:
    """Parse a simple KEY=VALUE config file, setting missing env vars."""
    if not os.path.isfile(path):
        return
    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            key, _, value = line.partition('=')
            key = key.strip()
            value = value.strip().strip('"').strip("'")
            if key and key not in os.environ:
                os.environ[key] = value

_load_config(_CONFIG_FILE)

# ---------------------------------------------------------------------------
# Runtime config
# ---------------------------------------------------------------------------
IFACE       = (sys.argv[1] if len(sys.argv) > 1 else '') or os.environ.get('IFACE', 'ens3')
HOOK_PATH   = os.environ.get('HOOK_PATH',  '/opt/bm-dhcp-tap/scripts/dhcp_hook2.sh')
LOG_FILE    = os.environ.get('LOG_FILE',   '/opt/bm-dhcp-tap/logs/bm-dhcp-tap.log')
SYSLOG_SRV  = os.environ.get('SYSLOG_SERVER', '')
SYSLOG_PORT = int(os.environ.get('SYSLOG_PORT', '514'))

# ---------------------------------------------------------------------------
# Logging — daemon-style format: TIMESTAMP HOSTNAME PID LEVEL message
#
# Handlers:
#   StreamHandler         — stdout, always on (user can redirect to /dev/null)
#   RotatingFileHandler   — LOG_FILE, 1 MB rolling window
#   SysLogHandler         — remote UDP syslog if SYSLOG_SERVER is set
# ---------------------------------------------------------------------------
_HOSTNAME = socket.gethostname()

# Rename INFO → INFORMATION to match level naming convention
logging.addLevelName(logging.INFO,    'INFORMATION')
logging.addLevelName(logging.WARNING, 'WARNING')
logging.addLevelName(logging.DEBUG,   'DEBUG')
logging.addLevelName(logging.ERROR,   'ERROR')

class _CtxFilter(logging.Filter):
    """Inject hostname into every log record."""
    def filter(self, record: logging.LogRecord) -> bool:
        record.hostname = _HOSTNAME
        return True

_FMT = '%(asctime)s %(hostname)s %(process)d %(levelname)s %(message)s'
_DATE_FMT = '%Y-%m-%dT%H:%M:%SZ'

_formatter = logging.Formatter(fmt=_FMT, datefmt=_DATE_FMT)
_formatter.converter = lambda *_: datetime.now(timezone.utc).timetuple()

_ctx_filter = _CtxFilter()

os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)

# stdout handler — always present
_stdout_handler = logging.StreamHandler(sys.stdout)
_stdout_handler.setFormatter(_formatter)
_stdout_handler.addFilter(_ctx_filter)

# rotating file handler — 1 MB, keep 1 backup
_file_handler = logging.handlers.RotatingFileHandler(
    LOG_FILE, maxBytes=1_048_576, backupCount=1
)
_file_handler.setFormatter(_formatter)
_file_handler.addFilter(_ctx_filter)

_handlers: list[logging.Handler] = [_stdout_handler, _file_handler]

# remote syslog handler — only when SYSLOG_SERVER is configured
if SYSLOG_SRV:
    _syslog_handler = logging.handlers.SysLogHandler(
        address=(SYSLOG_SRV, SYSLOG_PORT),
        facility=logging.handlers.SysLogHandler.LOG_USER,
    )
    _syslog_fmt = logging.Formatter(
        fmt='%(hostname)s %(process)d %(levelname)s %(message)s',
    )
    _syslog_fmt.converter = lambda *_: datetime.now(timezone.utc).timetuple()
    _syslog_handler.setFormatter(_syslog_fmt)
    _syslog_handler.addFilter(_ctx_filter)
    _handlers.append(_syslog_handler)

logging.basicConfig(level=logging.INFO, handlers=_handlers)
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
    if SYSLOG_SRV:
        log.info('Syslog enabled  server=%s  port=%d', SYSLOG_SRV, SYSLOG_PORT)

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
