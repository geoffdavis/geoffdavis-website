+++
date = '2026-03-28T00:00:00-07:00'
title = 'Bypassing Raspberry Pi 5 Network Death with USB 2.5GbE'
description = "When kernel patches couldn't fully fix RP1 Ethernet hangs, USB Ethernet adapters bypassed the problem entirely. Here's how to run a dual-interface Talos cluster on RPi5."
tags = ['raspberry-pi', 'linux', 'networking', 'talos', 'kubernetes', 'homelab', 'usb']
draft = false
+++

In the [previous post](/posts/rpi5-eee-silent-network-death/), I documented how the Raspberry Pi 5's built-in Ethernet — a BCM54213PE PHY connected through the RP1 southbridge via the `macb` driver — silently hangs due to a combination of AutogrEEEn and TSTART stalls. Six kernel patches reduced the hang frequency from every 2–3 minutes to every 19–90 minutes (depending on the node), and a netwatch DaemonSet shrinks each outage to ~4 seconds. But the hangs never stopped. Every one triggers a VIP migration and etcd leader election, churning the cluster even though nodes recover quickly.

After three days of monitoring the patched kernel, the answer was clear: the RP1/macb/BCM54213PE chain has a fundamental reliability problem that software can't fully resolve. The production fix is hardware — bypass `end0` entirely with USB 2.5GbE adapters.

## The Hardware

Three RTL8156BG USB 2.5GbE adapters (one per node), connected to a TP-Link TL-SG105S-M2 unmanaged 2.5GbE switch. The TP-Link uplinks to the UniFi Den-24-sw on port 23 (native VLAN 51). Each adapter gets its own RJ45 jack and its own cable run — no sharing the RP1 Ethernet path at any point.

{{< mermaid >}}
graph LR
    subgraph rpi["RPi5 Node"]
        cpu["BCM2712 SoC"]
        xhci["xHCI USB 3.0"]
        rp1["RP1 Southbridge"]
        mac["macb MAC"]
        cpu --- xhci
        cpu --- rp1
        rp1 --- mac
    end

    usb["RTL8156BG\nUSB 2.5GbE"]
    phy["BCM54213PE\nPHY"]
    tplink["TP-Link\nTL-SG105S-M2\n(2.5G unmanaged)"]
    unifi["UniFi\nDen-24-sw"]
    router["UDM Pro\nRouter"]

    xhci -->|"USB 3.0\n(r8152 driver)"| usb
    usb -->|"2.5GBASE-T\nVLAN 51 cluster"| tplink
    mac -->|"RGMII"| phy
    phy -->|"1000BASE-T\nVLAN 10 mgmt"| unifi
    tplink -->|"port 23\nnative VLAN 51"| unifi
    unifi --- router
{{< /mermaid >}}

The key insight: the USB adapter connects through the BCM2712 SoC's xHCI controller, not through RP1. The entire RP1 → macb → BCM54213PE path that causes the hangs is bypassed. The `r8152` driver has no EEE issues on RPi5.

## The Mode-Switch Problem

RTL8156BG adapters have a quirk: after a full power cycle, they enumerate as a USB mass storage device (vendor `0bda`, product `8151`) presenting a virtual CD-ROM with Windows drivers. The kernel's `usb-storage` driver claims the device before `r8152` ever sees it. Without intervention, the adapter stays in disk mode and never becomes a network interface.

The fix is a USB bus reset (`USBDEVFS_RESET` ioctl). After the reset, the adapter re-enumerates as `0bda:8156`, the `r8152-cfgselector` helper picks the Ethernet USB configuration, and the `r8152` driver binds automatically. The interface appears as `enP2p1s0u1`.

This needs to happen on every cold boot — and it needs to happen *early*, before etcd tries to start, because etcd is configured to wait for the USB adapter's IP address.

## Three Layers of Mode-Switch

Getting the timing right required three redundant mechanisms. Any one of them is sufficient, but having all three covers every boot scenario — cold boot, warm reboot, kexec, and DaemonSet restart.

{{< mermaid >}}
flowchart TD
    BOOT["Node powers on"] --> UDEV{"udev sees\n0bda:8151?"}
    UDEV -->|yes| RULE["Layer 1: udev rule\nruns /var/local/bin/rtl8156-modeswitch\n(earliest, before networking)"]
    RULE --> RENUM1["USB re-enumerates as 0bda:8156\nr8152 binds → enP2p1s0u1 appears"]

    UDEV -->|"no (race lost\nor warm boot)"| SPOD{"Static pod\nusb-modeswitch\nruns?"}
    SPOD -->|yes| STATIC["Layer 2: Talos static pod\nchecks /sys/bus/usb/devices/5-1/idProduct\nruns usbreset if PID=8151"]
    STATIC --> RENUM2["USB re-enumerates → r8152 binds"]

    SPOD -->|"no (pod\nnot yet scheduled)"| DS{"DaemonSet\ninitContainer\nruns?"}
    DS -->|yes| DAEMON["Layer 3: usb-modeswitch-rtl8156\nDaemonSet initContainer\napt-get install usb-modeswitch\nusb_modeswitch -R"]
    DAEMON --> RENUM3["USB re-enumerates → r8152 binds"]

    RENUM1 --> DHCP["DHCP on VLAN 51\n→ 172.29.51.x"]
    RENUM2 --> DHCP
    RENUM3 --> DHCP
    DHCP --> ETCD["etcd starts\n(advertisedSubnets\nmatches USB IP)"]
{{< /mermaid >}}

### Layer 1: udev rule (earliest)

A udev rule in the Talos machine config fires the moment the kernel sees `0bda:8151`:

```text
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", \
  ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8151", \
  RUN+="/var/local/bin/rtl8156-modeswitch"
```

The script at `/var/local/bin/rtl8156-modeswitch` is a shell wrapper around a statically compiled `usbreset` binary (embedded as base64). It sends `USBDEVFS_RESET` on the device path, causing re-enumeration. This runs before Talos configures networking — the earliest possible point.

### Layer 2: Talos static pod

A static pod defined in `machine.pods` runs on every boot before etcd starts:

```yaml
machine:
  pods:
    - apiVersion: v1
      kind: Pod
      metadata:
        name: usb-modeswitch
        namespace: kube-system
      spec:
        hostNetwork: true
        restartPolicy: Always
        containers:
          - name: modeswitch
            image: busybox:latest
            securityContext:
              privileged: true
            command: ["/bin/sh", "-c"]
            args:
              - |
                if [ -e /sys/bus/usb/devices/5-1/idProduct ]; then
                  PID=$(cat /sys/bus/usb/devices/5-1/idProduct)
                  if [ "$PID" = "8151" ]; then
                    /var/local/bin/rtl8156-modeswitch /dev/bus/usb/005/002
                  fi
                fi
                sleep infinity
```

This catches cases where the udev rule lost the race (the device enumerated before the rule was loaded).

### Layer 3: Kubernetes DaemonSet (backup)

A DaemonSet with an `initContainer` installs `usb-modeswitch` from apt and runs `usb_modeswitch -R` if `0bda:8151` is still present. This is the heaviest mechanism (pulls packages at boot) but the most robust — it runs in a full Linux userspace and can log diagnostics.

### Preventing usb-storage from claiming the device

One more piece: a kernel module parameter tells `usb-storage` to ignore the RTL8156BG's disk-mode identity:

```yaml
machine:
  kernel:
    modules:
      - name: usb-storage
        parameters:
          - quirks=0bda:8151:i    # 'i' = IGNORE_DEVICE
      - name: r8152               # pre-load so it's registered before mode-switch
```

The `i` quirk prevents `usb-storage` from binding to `0bda:8151`, giving the mode-switch script time to reset the device before any driver claims it.

## Dual-Interface Network Architecture

With the USB adapter working, the cluster runs a dual-interface setup:

| Interface | Driver | VLAN | Purpose | IPs |
|-----------|--------|------|---------|-----|
| `enP2p1s0u1` | r8152 (USB) | 51 (cluster) | etcd, API server, pod networking, VIP | .11/.12/.13 on 172.29.51.0/24 |
| `end0` | macb (RP1) | 10 (mgmt) | Emergency `talosctl` access, monitoring | .11/.12/.13 on 172.29.10.0/24 |

The VIP (172.29.51.10) floats on `enP2p1s0u1` across the three control plane nodes. `end0` is demoted to a high-metric fallback — it still gets a DHCP lease and responds to `talosctl`, but no cluster traffic touches it.

{{< mermaid >}}
graph TB
    subgraph cluster["Cluster Traffic (VLAN 51)"]
        direction LR
        vip["VIP\n172.29.51.10"]
        n1u["pi5-01\nenP2p1s0u1\n172.29.51.11"]
        n2u["pi5-02\nenP2p1s0u1\n172.29.51.12"]
        n3u["pi5-03\nenP2p1s0u1\n172.29.51.13"]
    end

    subgraph mgmt["Management Fallback (VLAN 10)"]
        direction LR
        n1e["pi5-01\nend0\n172.29.10.11"]
        n2e["pi5-02\nend0\n172.29.10.12"]
        n3e["pi5-03\nend0\n172.29.10.13"]
    end

    etcd["etcd peers"]
    api["kube-apiserver"]
    pods["Pod networking\n(Cilium VXLAN)"]
    talosctl["talosctl\n(emergency)"]
    netwatch["netwatch\n(still monitors end0)"]

    etcd --> cluster
    api --> cluster
    pods --> cluster
    talosctl --> mgmt
    netwatch --> mgmt
{{< /mermaid >}}

### Talos configuration

The per-node network config in `talconfig.yaml` sets up both interfaces with `end0` at a higher route metric (lower priority):

```yaml
networkInterfaces:
  - interface: end0
    dhcp: true
    dhcpOptions:
      routeMetric: 4096          # low priority — mgmt fallback only
  - interface: enP2p1s0u1
    dhcp: true
    vip:
      ip: 172.29.51.10           # VIP floats on USB adapter
```

etcd is told to advertise only on the USB adapter's subnet, so peers never try to reach each other over `end0`:

```yaml
cluster:
  etcd:
    advertisedSubnets:
      - 172.29.51.0/24           # USB adapter IPs only
```

And kubelet accepts node IPs from either subnet, preferring the USB adapter:

```yaml
machine:
  kubelet:
    nodeIP:
      validSubnets:
        - 172.29.51.0/24         # cluster VLAN (USB) — primary
        - 172.29.10.0/24         # management VLAN (end0) — fallback
```

### Boot sequence

The order matters. etcd won't start until it has an IP matching `advertisedSubnets`, which means the USB adapter must be mode-switched and DHCP'd before etcd initialization:

1. `end0` gets management IP immediately (172.29.10.x) via DHCP
2. udev / static pod triggers USB mode-switch → `enP2p1s0u1` appears
3. DHCP on VLAN 51 → cluster IP (172.29.51.x)
4. etcd starts — `advertisedSubnets` matches the USB adapter IP
5. VIP (172.29.51.10) election runs on `enP2p1s0u1`
6. API server binds, kubelet registers, pods schedule

If the USB adapter fails to mode-switch (all three layers fail), the node still boots with `end0` on VLAN 10. kubelet registers with the management IP as a fallback. The node is operational but isolated from the cluster VLAN — `talosctl` works, but pod networking and etcd peering won't function until the USB adapter comes up.

## Results

Since deploying the dual-interface setup: **zero cluster-impacting network outages.**

The `end0` hangs still happen — netwatch logs show link toggles every 20–90 minutes on all three nodes. But those hangs now only affect the management interface. etcd, the API server, pod networking, Longhorn replication, and the VIP all run over the USB adapter and are completely unaffected.

| Before (single interface) | After (dual interface) |
|---------------------------|------------------------|
| Every hang → VIP migration + etcd leader election | Hangs only affect management access |
| etcd term counter advancing by 4–5 every 7 minutes | etcd stable, no spurious elections |
| Longhorn engine timeouts on 30s hangs | Longhorn unaffected |
| Prometheus scrape gaps every few minutes | Clean scrape data |

The kernel patches and netwatch DaemonSet remain deployed on `end0` as defense-in-depth for the management interface. If the USB adapter ever fails, `end0` is still there — degraded but functional — and netwatch keeps it recovering.

## The `usbreset` Binary

The mode-switch relies on a small C program that sends `USBDEVFS_RESET`:

```c
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/usbdevice_fs.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: usbreset <device>\n");
        return 1;
    }
    int fd = open(argv[1], O_WRONLY);
    if (fd < 0) { perror("open"); return 1; }
    int rc = ioctl(fd, USBDEVFS_RESET, 0);
    if (rc < 0) { perror("USBDEVFS_RESET"); }
    close(fd);
    return rc < 0 ? 1 : 0;
}
```

Cross-compile for `aarch64` (the RPi5 architecture), base64-encode, and embed it in the shell wrapper at `/var/local/bin/rtl8156-modeswitch`. Talos's read-only rootfs means you can't install packages at runtime — everything must be baked into the machine config or delivered via container images.

## Lessons Learned

**Bypass beats fix.** Three weeks of kernel patch iteration — AutogrEEEn disable, BCM54213PE PHY init, RPi Foundation backport, TSR pre-flush — improved things but never reached stability. Three USB adapters and an afternoon of config work solved the problem completely. Sometimes the right answer is to route around the damage.

**Defense in depth for boot-time hardware.** The RTL8156BG mode-switch problem could have been a single udev rule. But Talos's boot sequence has enough timing variability that a single mechanism isn't reliable. The three-layer approach (udev → static pod → DaemonSet) hasn't failed a single boot across hundreds of power cycles.

**Keep the old path alive.** `end0` is still configured, still monitored by netwatch, and still reachable via `talosctl`. When you're debugging a node that won't join the cluster, having a second network path that doesn't depend on Kubernetes being healthy is invaluable.

---

The full configuration lives in [pi-talos-home-ops](https://github.com/geoffdavis/pi-talos-home-ops): machine config patches in `talos/patches/global.yaml`, the DaemonSet in `kubernetes/bootstrap/usb-modeswitch-daemonset.yaml`, and the `usbreset` source in `hack/usbreset/usbreset.c`. The EEE kernel patches (still applied for `end0` defense-in-depth) are in [geoffdavis/siderolabs-pkgs](https://github.com/geoffdavis/siderolabs-pkgs) under `kernel/build/patches/eee/`.
