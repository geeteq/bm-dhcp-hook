# BM Provisioning Pipeline

Automated baremetal server provisioning pipeline. Each phase transitions a server
through its lifecycle in NetBox, from first network appearance to ready-for-tenant.

---

## Lifecycle States

```
offline → discovered → staged → ready → active
```

---

## Phase 0 — DHCP Discovery (scripts/dhcp_hook2.sh)

**Trigger:** Automatic — ISC dhcpd fires the hook on every lease commit.

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

This section was generated by Claude Sonnet 4.6 within an interactive session.
Estimated token cost for this specific addition:

| | Tokens | Cost (Sonnet 4.6) |
|---|---|---|
| Input context (conversation + files) | ~55,000 | ~$0.17 |
| Output (this section) | ~900 | ~$0.01 |
| **Total** | **~55,900** | **~$0.18** |

Pricing: $3.00 / 1M input tokens · $15.00 / 1M output tokens.
The bulk of cost is input context — the accumulated conversation history,
file contents, and tool outputs from the session, not the content generated.

---

## Dependencies

- bash 4+, curl, jq
- NetBox (NETBOX_URL, NETBOX_TOKEN)
- ISC DHCP server (Phase 0)
- PXE infrastructure — TFTP + HTTP server serving the validation image (Phase 1)
- Ansible control node (Phase 2)
