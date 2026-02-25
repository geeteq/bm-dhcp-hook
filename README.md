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

## Dependencies

- bash 4+, curl, jq
- NetBox (NETBOX_URL, NETBOX_TOKEN)
- ISC DHCP server (Phase 0)
- PXE infrastructure — TFTP + HTTP server serving the validation image (Phase 1)
- Ansible control node (Phase 2)
