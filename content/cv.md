+++
date = '2026-03-18T12:21:44-07:00'
draft = false
title = 'CV'
+++

## Geoffrey A. Davis

San Diego, CA | [geoffdavis.com](https://geoffdavis.com) | [GitHub](https://github.com/geoffdavis) | [LinkedIn](https://www.linkedin.com/in/geoffrey-davis-b978201)

---

Infrastructure engineer with 25+ years of experience building and operating
resilient, large-scale systems for research networks, public utilities, and
emergency services. Background spanning carrier-grade wireless networks,
petabyte-scale seismic data infrastructure, statewide wildfire detection systems,
and shipboard computing. Early adopter of AI-augmented DevOps workflows.

---

## Professional Experience

### Oceaneering International — Senior DevOps Administrator

*March 2026 – Present*

DevOps engineering for offshore energy, ROV operations, and subsea
infrastructure.

### Scripps Institution of Oceanography, UC San Diego

*October 2002 – February 2026*

Progressed through three title levels over a 23-year tenure spanning multiple
large-scale research infrastructure projects. Titles held:

- **Information Systems Analyst IV** (2018–2026)
- **Programmer/Analyst III** (2005–2018)
- **Programmer/Analyst II** (2002–2005)

#### HPWREN — High Performance Wireless Research & Education Network

*NOC Director & Lead Network Architect*

Operated [AS46985](https://bgp.he.net/AS46985), a multi-institutional
carrier-grade wireless research network spanning 50+ backbone sites across six
Southern California counties. Provided managed IP services, WISP connectivity,
and sensor network infrastructure to 20+ partner organizations including Caltech
(Mount Palomar Observatory), SDSU, UCSB, SDG&E, CalFire, and California State
Parks.

- Engineered fault-tolerant MPLS/BGP network with multiple failover paths
  serving diverse SLA requirements across research, education, and emergency
  services
- Designed for zero-touch operations at remote mountain-top sites, implementing
  comprehensive out-of-band management that eliminated routine truck rolls to
  locations only accessible by helicopter during fire season
- Saved $70K+ through strategic infrastructure consolidation
- Led 24/7 on-call rotation with blameless incident response practices
- Leveraged AI tools (Claude/KiloCode) to refactor entire Puppet codebase in 2
  weeks vs. 2–3 months traditionally, achieving 95% test coverage and removing
  1000+ lines of technical debt

#### AlertCalifornia — Statewide Wildfire Detection Camera Network

*Chief Network Architect*

Designed the network architecture for a statewide system of 1500+ wildfire
detection cameras spanning 40+ infrastructure providers.

- Architected camera exchange network with comprehensive monitoring and security
  visibility
- Built redundant datacenter architecture with automated failover between sites
- Established IPSec/BGP interconnects between AWS, Azure, and on-premises
  infrastructure
- Implemented NetBox DCIM for infrastructure visibility and automated
  provisioning

#### USArray Transportable Array / Array Network Facility (EarthScope)

*Lead Systems & Storage Architect*

Managed computing and storage infrastructure for the NSF-funded EarthScope
seismic monitoring program, supporting continuous data acquisition from 1700+
globally distributed sensors with 40 station moves per month and a 99.5% data
return rate.

- Designed storage evolution maintaining zero downtime: DAS → SAN → virtualized
  ZFS with live migrations across 50+ compute and storage nodes
- Optimized workload distribution reducing real-time seismic event detection
  latency by ~20x
- Built self-documenting infrastructure rebuildable from code in minutes
- Co-managed the antelope_contrib seismic software repository for 10+ years

#### ROADNet — Real-time Observatories, Applications, and Data Management Network

*Computing Systems Lead*

Eliminated configuration drift across global sensor deployments using CFEngine.
Built automated provisioning pipeline for partner organizations.

#### Shipboard Computing / HiSeasNet

*Systems Engineer — 20+ years*

Supported C-band satellite connectivity for the UNOLS oceanographic research
fleet. Designed autonomous computing systems operating without network
connectivity for weeks at sea. Published in *Marine Technology* magazine on the
SWAP ship-to-ship mesh network.

### Rangefire Integrated Networks, Santa Barbara, CA — Network Engineer

*1999 – 2002*

Managed ISP infrastructure including DDoS mitigation and incident response.
Developed monitoring and alerting systems for proactive issue detection.

---

## Education

**University of California, Santa Barbara** — B.S. Computer Science, 2000

---

## Certifications & Training

- Tower Safety and Rescue
- Puppet Advanced
- Ansible Automation

---

## Technical Skills

**Networking:** BGP, OSPF, MPLS, EVPN, EIGRP; Cisco, Arista, MikroTik,
Ubiquiti

**Automation & IaC:** Puppet (15 years), Ansible, Terraform/Terragrunt, Nornir,
Python, CFEngine; 21+ years of Infrastructure as Code experience

**Cloud:** AWS (broad), Azure (interconnection-focused)

**Containers & Virtualization:** Kubernetes (Talos/Rancher), Docker, Proxmox,
VMware, Sun Cluster

**Storage:** ZFS, SAM-QFS, SAN, Ceph

**Observability:** NetBox IPAM/DCIM, LibreNMS, Nagios, Intermapper

**AI-Augmented DevOps:** Claude, KiloCode — actively used for infrastructure
code refactoring, architecture planning, and migration strategies

---

## Open Source

- **[esphome-mitsubishiheatpump](https://github.com/geoffdavis/esphome-mitsubishiheatpump)**
  — ESPHome climate component for Mitsubishi heat pumps via direct serial
  connection (650+ stars)
- **antelope_contrib** — Co-maintainer of the Antelope seismic software
  community repository (10+ years)
- **Puppet modules** — Author of multiple infrastructure automation modules
  including puppet-zfsonlinux
- 40+ public repositories on GitHub

---

## Publications

- *Marine Technology* — SWAP network: ship-to-ship mesh networking for the
  oceanographic research fleet
