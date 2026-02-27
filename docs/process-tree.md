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
- Check system disk perfomance with fio
    - log baseline perfomance to NetBox 
- Check memory performance
    - log baseline perfomance to NetBox 
- Update NetBox with found information

## 
