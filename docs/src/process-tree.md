# Server Provisioning

## Offline
- Server is ordered
- Server is in transit
- Server is received and GRd
- Factory output file is loaded to NetBox
- Server is assigned to tenant or baremetal-reserve tenant

## CLLI Placeholder
- Server is received on-site
- Server is racked
- Server is cabled
- Server is powered on

## Planned
- DHCP discovery is triggered
- Server is PXE booted to test Linux image
- Hardware tests are run
    - Inventory in checked with dmidecode
    - Get server hardware info such as
        - Serial
        - Model
        - Vendor
        - CPU
        - RAM
        - DISK
        - Network cards
- Check cabling via LLDP
    - Run lldp discovery script
    - Check 

## Staged
    - Phase 1: Configuration mgt
    - Phase 2: Deployment
    - Phase 3: Verification & network discovery
    - Phase 4: HW health
    - Phase 5: TOR enablement
    - Phase 6: handover -> active

## Active
    - Tenant welcome packet is generated
    - Tenant is notified of servers delivered
    - JIRA ICA ticket is closed and servers are delivered


