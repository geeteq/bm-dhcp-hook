# BM Provisioning Pipeline

Automated baremetal server provisioning pipeline. Each phase transitions a server
through its lifecycle in NetBox, from first network appearance to ready-for-tenant.

---

## Lifecycle States

```
offline → discovered → staged → ready → active
```

---

## Phase 0 — DHCP Discovery

### DHCP tap (tools/bm-dhcp-tap.py + tools/bm-dhcp-tap.service)

**Trigger:** Automatic — `bm-dhcp-tap.py` runs as a systemd service on the MAAS
rack controller host OS and fires `dhcp_hook2.sh` on every DHCP ACK.

MAAS 3.3+ runs inside a snap with an ephemeral filesystem, so scripts cannot be
installed inside it. `bm-dhcp-tap.py` runs outside the snap and uses a raw
`AF_PACKET` socket to capture DHCP packets directly off `ens3` (the BMC management
interface). It parses the Ethernet frame in pure Python (no external deps), checks
for DHCP ACK (BOOTP op=2, option 53=5), extracts `yiaddr` (IP), `chaddr` (MAC),
and option 12 (hostname), then spawns `dhcp_hook2.sh`.

See `docs/bm-dhcp-tap-flow.dot` for the packet-parsing flow diagram.

Install path: `/opt/bm-dhcp-tap/`

### Hook + FSM (scripts/dhcp_hook2.sh + scripts/lib/bmc-fsm.sh)

The hook filters for known BMC vendor MACs (HPE iLO, Dell iDRAC, etc.), looks the
device up in NetBox by MAC address, and drives a simple FSM:

| Device state | Action |
|---|---|
| `offline` | Promote to `discovered`, assign BMC IP to interface |
| `discovered` | Refresh BMC IP |
| `active` — no IP on record | Assign BMC IP |
| `active` — IP matches | No action |
| `active` — IP mismatch | Journal warning, no change |
| Any other state | Journal warning, no action |

After Phase 0 completes the device is `discovered` and its BMC IP is recorded in
NetBox. It is now available for staging.

See `docs/dhcp-hook2-flow.dot` for the full state machine diagram.

---

## Tools

### netbox_load_bmc_mac.sh

Bulk-loads BMC MAC addresses into NetBox from a CSV of server serial numbers. Used
during initial server intake when the manufacturer order manifest arrives with MAC
addresses before the servers are racked.

```
Usage: tools/netbox_load_bmc_mac.sh <input.csv>

CSV format (header required):
  server_serial,server_bmc_mac
  MXP1111111,A0:36:9F:7C:05:00
```

For each row the script:
1. Looks up the device in NetBox by serial number (fails loudly if not found)
2. Finds the BMC interface — matches `bmc`, `ilo`, `idrac` in any case
3. If the interface already has a **different** MAC: journals a warning, skips
4. If the interface has **no MAC**: sets it from the CSV, journals success

Exit code is non-zero if any row failed.

---

## Phase 1 — PXE Validation (in progress)

**Trigger:** Manual — onsite tech powers on the server.

Once powered on, the server PXE boots automatically and runs a suite of validation
scripts. Results are journaled to NetBox at each step. On overall pass the device
transitions to `staged`.

### Validation steps

| Script | Test |
|---|---|
| `01-init.sh` | Hardware inventory via dmidecode; find device in NetBox by serial / MAC |
| `02-memory.sh` | Memory test via memtester |
| `03-disk.sh` | Disk I/O benchmarks via fio (sequential + random, read + write) |
| `04-lldp.sh` | LLDP neighbour discovery; map NICs to switch ports |
| `05-report.sh` | Aggregate results; POST callback event; set device `staged` on pass |

See `docs/phase1-flow.dot` for the flow diagram.

---

## Phase 2 — Hardening (planned)

**Trigger:** TBD — likely automatic on `staged`.

Ansible playbooks apply BMC hardening profiles (firmware updates, BIOS settings,
iLO/iDRAC hardening). On completion the device transitions to `ready`.

---

## Future State — Production Architecture

The POC uses shell scripts calling NetBox directly. A production deployment
serving multiple datacenters needs each function to be independently deployable,
observable, and fault-tolerant. The natural evolution is an event-driven
architecture with Kafka as the enterprise service bus.

### Why Kafka

Every action in this pipeline is a discrete event: a DHCP lease, a PXE
completion, a telemetry sample, a hardware alert. Kafka turns the pipeline
into a durable, replayable log. Any service can consume any event. Failed
consumers replay from offset without data loss. New services (billing,
compliance, analytics) subscribe to existing topics with zero changes to
producers.

### Topics

| Topic | Producer | Description |
|---|---|---|
| `bm.dhcp.events` | DHCP hook | Raw DHCP lease commits (IP, MAC, hostname) |
| `bm.device.state` | Discovery service | Device lifecycle state transitions |
| `bm.pxe.events` | PXE callback API | Validation phase results (per-script pass/fail) |
| `bm.hardening.events` | Ansible runner | Playbook completion and results |
| `bm.telemetry` | Redfish poller | CPU, power, thermal metrics per device |
| `bm.hw.alerts` | Monitoring service | Hardware fault events |
| `bm.delivery` | Delivery service | Tenant order fulfilment events |

### Services

| Service | Replaces | Consumes | Produces |
|---|---|---|---|
| **Discovery** | `dhcp_hook2.sh` + `bmc-fsm.sh` | `bm.dhcp.events` | `bm.device.state` |
| **Staging** | Phase 1 callback receiver | `bm.pxe.events` | `bm.device.state` |
| **Hardening** | Ansible ad-hoc | `bm.device.state` (staged) | `bm.hardening.events` |
| **Delivery** | Manual | `bm.hardening.events` | `bm.delivery` |
| **Telemetry** | — | `bm.telemetry` | Prometheus remote-write |
| **Alerting** | — | `bm.hw.alerts` + `bm.telemetry` | Jira tickets |
| **Portal** | — | `bm.device.state` + `bm.delivery` | Tenant UI events |
| **Notification** | Manual email | `bm.delivery` | Email / webhook to tenant |

### Topology

```
                         ┌─────────────────────────────────────────┐
                         │              Apache Kafka                │
   DHCP hook ──────────► │  bm.dhcp.events                         │
   PXE callback ────────►│  bm.pxe.events       ┌──────────────────┤
   Redfish poller ──────►│  bm.telemetry         │  Discovery svc   │──► NetBox
   Ansible runner ──────►│  bm.hardening.events  │  Staging svc     │──► NetBox
   Monitoring ──────────►│  bm.hw.alerts         │  Hardening svc   │──► Ansible
                         │  bm.device.state      │  Telemetry svc   │──► Prometheus
                         │  bm.delivery          │  Alerting svc    │──► Jira
                         └───────────────────────│  Portal svc      │──► Tenant UI
                                                 │  Notification svc│──► Email/webhook
                                                 └──────────────────┘
```

### Scalability characteristics

- **Multi-datacenter**: each DC runs its own DHCP hook and Redfish pollers as
  producers; a single Kafka cluster (or per-DC cluster with MirrorMaker) fans
  events to centralised consumers
- **Horizontal scaling**: consumers are stateless — add replicas per consumer
  group to increase throughput
- **Resilience**: Kafka retains messages; a crashed service replays from its last
  committed offset on restart, no events are lost
- **Auditability**: the full event log is the audit trail — replay any device's
  history from its first DHCP lease
- **Extensibility**: new services (cost accounting, warranty lookup, refresh
  calculator) subscribe to existing topics with no changes to any producer

### Migration path from POC

```
POC (now)                     Production
─────────────────────         ──────────────────────────────────────
dhcp_hook2.sh                 → Discovery service (Python/Go)
  └─ bmc-fsm.sh (direct API)    └─ publishes to bm.dhcp.events
                                   consumes, writes NetBox via API

Phase 1 callback              → Staging service
  └─ 05-report.sh               └─ consumes bm.pxe.events

Ansible ad-hoc                → Hardening service
                                └─ triggered by bm.device.state=staged

Manual delivery               → Delivery + Notification services
```

---

## AI Generation Note

The entire codebase (Phase 0 + Phase 1 scripts, FSM library, Graphviz diagrams,
README, TODO) was generated by Claude Sonnet 4.6 in an interactive session.

### Codebase size

| Artifact | Lines | Characters | Output tokens (÷4) |
|---|---|---|---|
| `dhcp_hook2.sh` | 69 | 2,970 | ~740 |
| `lib/bmc-fsm.sh` | 408 | 16,167 | ~4,040 |
| `tools/bm-dhcp-tap.py` | 147 | 5,320 | ~1,330 |
| `tools/bm-dhcp-tap.service` | 34 | 1,050 | ~260 |
| `tools/netbox_load_bmc_mac.sh` | 118 | 4,210 | ~1,050 |
| `docs/dhcp-hook2-flow.dot` | 96 | 4,517 | ~1,130 |
| `docs/bm-dhcp-tap-flow.dot` | 95 | 4,300 | ~1,075 |
| `docs/phase1-flow.dot` | 112 | 5,423 | ~1,360 |
| `docs/bmc-flow.dot` (poc) | 409 | 19,909 | ~4,980 |
| PXE validation scripts (6) | 640 | 24,882 | ~6,220 |
| `README.md` + `TODO` | 280 | 12,100 | ~3,025 |
| **Total** | **2,418** | **100,848** | **~25,210** |

### Session cost estimate

Generation was iterative — each fix, test run, and refinement added turns and
accumulated context. An API turn's input cost = full conversation history to that
point, not just the new message.

| | Tokens | Cost |
|---|---|---|
| Output — code + prose generated | ~70,000 | $1.05 |
| Input — context × ~50 turns (avg 25K/turn) | ~1,250,000 | $3.75 |
| **Session total** | **~1,320,000** | **~$4.80** |

### Clean generation vs iterative development

A clean one-shot generation of the same codebase (no debugging, no iteration)
would cost significantly less because context stays smaller throughout:

| | Iterative session (actual) | Clean generation (estimated) |
|---|---|---|
| Turns | ~50 | ~15 |
| Avg input context / turn | ~25,000 tokens | ~12,000 tokens |
| Total input tokens | ~1,250,000 | ~180,000 |
| Total output tokens | ~70,000 | ~25,000 |
| **Estimated cost** | **~$4.80** | **~$0.92** |

The 5× cost difference comes entirely from iterative context accumulation —
debugging, testing, and refining adds far more input tokens than it adds output.

Pricing: $3.00 / 1M input · $15.00 / 1M output (Claude Sonnet 4.6, Feb 2026).

---

## Dependencies

- bash 4+, curl, jq
- Python 3 (stdlib only — for bm-dhcp-tap.py)
- NetBox (`NETBOX_URL`, `NETBOX_TOKEN`)
- MAAS 3.x rack controller — DHCP tap runs on the host OS outside the snap
- PXE infrastructure — TFTP + HTTP server serving the validation image (Phase 1)
- Ansible control node (Phase 2)
