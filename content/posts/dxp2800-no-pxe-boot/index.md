+++
date = '2026-07-02T20:00:00-07:00'
title = 'Your UGREEN DXP2800 Cannot PXE Boot'
description = "The UGREEN NASync DXP2800's AMI firmware ships without a UEFI PXE boot agent for its Intel I226-V NICs. Network Stack enabled, IPv4 PXE Support enabled, Fast Boot disabled, Network first in the boot order — and the firmware never sends a single DHCP packet. Nothing in BIOS setup fixes it. Here's the evidence, the hidden BIOS key (Ctrl+F12), and what to use instead."
tags = ['ugreen', 'nas', 'pxe', 'netboot', 'uefi', 'bios', 'firmware', 'homelab', 'jetkvm', 'nixos']
draft = true
+++

If you're trying to network-boot a UGREEN NASync DXP2800 — to install a third-party OS, run a rescue image, or wire it into an existing PXE/netboot.xyz setup — stop adjusting your DHCP server. It's not your DHCP server. The DXP2800's firmware ships **without a UEFI PXE boot agent for its network controllers**. Every PXE-related toggle in BIOS setup is present and settable, and none of them do anything. The machine cannot PXE boot, full stop, and nothing in firmware setup will change that.

I couldn't find this documented anywhere — not in UGREEN's materials, not in the community wikis, not in any forum thread — so here it is, from my own bench, so the next person's search has somewhere to land.

**Up front**: I am a paying UGREEN customer. I bought three NASync DXP units at full retail, and I'm broadly happy with the hardware. This isn't a takedown; it's a heads-up about a limitation that only surfaces if you try to boot these boxes from the network — which UGOS itself never does, so UGREEN plausibly never noticed or never cared.

**TL;DR**:

- The DXP2800 (Intel N100, dual Intel I226-V 2.5GbE, AMI firmware, 32GB eMMC boot device) **never attempts DHCP/PXE at boot**, even with Network Stack enabled, IPv4 PXE Support enabled, Fast Boot disabled, and "Network" first in the boot order.
- Enabling the network stack **never publishes a UEFI PXE boot entry** for either NIC — on typical AMI firmware you'd get a `UEFI: PXE IPv4 Intel(R) Ethernet Controller I226-V` entry after a reboot. Here, nothing ever appears. The "Network" boot-order entry is inert.
- The likely cause: the firmware image simply **doesn't include a UEFI network boot driver for the I226-V**. The PXE menu options are generic AMI setup plumbing with nothing behind them.
- Control experiment: the exact same PXE infrastructure (DHCP options 66/67 pointing at netboot.xyz) boots virtual machines end-to-end on the same network segment. The network side is proven good; the DXP2800's firmware is the missing link.
- What works instead: **USB boot** (Ventoy is convenient), or — the fully-remote path — **IP-KVM virtual media** (a JetKVM's mounted ISO shows up as USB mass storage at UEFI boot and works great on this box).
- Bonus standalone knowledge: BIOS setup on these boxes is behind **Ctrl+F12** at the UGREEN splash screen (Del and F2 do nothing).

Verified on a DXP2800 with the firmware it shipped with in 2026. Other NASync models are untested — the DXP8800's platform differs — and a future BIOS update could change this. Scope your expectations accordingly.

## How I Got Here

I was preparing a NixOS install for one of my three DXP units. The plan was the boring, proven one: PXE-chain into [netboot.xyz](https://netboot.xyz/), pick the installer, done. The PXE server sat ready, the DHCP options were in place, and the same setup had already booted other machines on the network.

The DXP2800 just wouldn't look at the network. Not "failed to boot" — *never tried*. No DHCP request in the server logs, no `>>Start PXE over IPv4` message on screen, no link-negotiation pause. Power on, UGREEN splash, GRUB. Every time.

That kicked off an hour of methodical BIOS spelunking, which is where the useful findings start.

## Getting Into BIOS Setup at All

First hurdle: the usual keys don't work. **Del and F2 do nothing** on the DXP2800. If you've been mashing them at the splash screen and concluding the BIOS is locked away, it isn't — it's just on a non-standard key:

- **Ctrl+F12** at the UGREEN splash screen enters AMI BIOS setup. The usual Del and F2 do nothing — Ctrl+F12 is the only chord that works, and it's easy to miss because there's no on-screen prompt for it.

This is worth knowing independent of the PXE question. (If you're wondering about Ctrl+F1 — the AMI "unlock advanced menus" chord that works on some vendors' firmware — it does nothing here; every setup page these boxes expose, including the network stack settings discussed below, is already visible once you're in.)

(A JetKVM or any HID-emulating IP-KVM can send these chords remotely, which matters later.)

## The Experiment

With access to the full setup tree, I configured everything PXE needs, exactly as you would on any AMI UEFI system:

| Setting | Value |
| ------- | ----- |
| Network Stack | **Enabled** |
| IPv4 PXE Support | **Enabled** |
| Fast Boot | **Disabled** |
| Boot order | **Network** first |

Save, reboot. Expected on any normal AMI box: a link-wait, then `>>Start PXE over IPv4`, then a DHCP request hitting the server.

Observed: AMI splash → GRUB. Directly. No delay, no PXE banner, no DHCP packet on the wire. The firmware never even brought the NIC up to ask.

Second tell, and the diagnostic one: on typical AMI firmware, enabling the network stack causes the firmware to bind its network boot driver to each NIC and publish per-NIC boot entries — something like `UEFI: PXE IPv4 Intel(R) Ethernet Controller I226-V` — visible in the boot-override list after the next reboot. On the DXP2800, **no such entry ever appears**, no matter how many reboots you give it. The generic "Network" entry in the boot order has no device behind it. It's inert.

That combination — settings accepted, no boot entry published, no DHCP attempt — points at one conclusion: the firmware image ships **no NIC boot agent / UEFI PXE driver for the I226-V controllers**. The setup options are stock AMI plumbing that toggles a stack with no driver to bind. There is nothing in setup that can fix this, because the missing piece isn't a setting — it's code that was never included.

## Ruling Out the Network

The obvious objection: "your PXE setup is broken." Fair, so I controlled for it.

The same infrastructure — DHCP options 66/67 pointing at a TFTP server hosting the netboot.xyz loader — boots virtual machines end-to-end on the same network segment: DHCP offer, TFTP transfer, netboot.xyz menu, installer. Same DHCP server, same options, same segment, same everything except the client.

The network side is proven good. The DXP2800 is the only client that never sends the first packet. The firmware is the missing link, not the LAN.

## Why UGREEN Probably Doesn't Care

UGOS boots from the internal 32GB eMMC. A stock DXP2800 never network-boots at any point in its supported life — not for install, not for recovery, not for updates. From UGREEN's perspective, a PXE driver is dead weight in the firmware image serving a use case they don't support.

The only people who hit this are people doing what I was doing: netbooting an installer for a third-party OS. That's a small population, but it's a population that *specifically* buys N100 boxes with dual 2.5GbE, and every one of them will hit this wall and — until now — find zero search results explaining it.

## What to Do Instead

Three options, in increasing order of remoteness:

### 1. USB boot (works fine)

USB boot is fully functional. Write your installer to a stick, plug it in, and either let boot order pick it up or use the boot-override menu from setup. [Ventoy](https://www.ventoy.net/) is convenient here — one stick, many ISOs, no re-flashing between attempts.

### 2. IP-KVM virtual media (the fully-remote path)

This is the one that actually replaces PXE for remote reinstalls. An IP-KVM with virtual-media support — I use a [JetKVM](https://jetkvm.com/) — presents a mounted ISO to the box as USB mass storage, visible to the UEFI firmware at boot like any physical stick.

On the JetKVM: **Mount Drive**, pick the ISO, and use **CD/DVD mode** for images over 2.2GB (installer ISOs usually are). The DXP2800's firmware sees the virtual drive immediately, it shows up in the boot menu, and it boots. The KVM also sends the Ctrl+F12 chord, so the entire loop — enter setup, pick boot device, install OS — works without touching the machine.

This is how the NixOS install that started all this actually got done, and it works great on this box. If your DXP unit lives somewhere you don't, this is the setup to have in place *before* you need it.

### 3. Wait for a firmware update (don't hold your breath)

A future BIOS update could add a network boot driver. Given that UGOS never needs one, I wouldn't plan around it. If a later firmware changes this, I'll update this post.

## Summary

The UGREEN NASync DXP2800 cannot PXE boot. The firmware exposes all the standard AMI network-boot settings — Network Stack, IPv4 PXE Support, boot-order Network entry — but ships no UEFI PXE driver for its Intel I226-V NICs, so those settings are connected to nothing. No DHCP request is ever emitted, and no per-NIC PXE boot entry ever appears. This is a firmware limitation, verified against a known-good PXE environment, and no BIOS setting fixes it.

If you're trying to netboot one: use a USB stick, or better, an IP-KVM with virtual media. And remember **Ctrl+F12** for setup — it's the only chord that gets you in.

If you have a DXP2800 on newer firmware where PXE *does* work, or another NASync model where you've tested this either way, I'd genuinely like to hear about it — email me at the address at the bottom of any page on this site, and I'll update the post with model/firmware data points.
