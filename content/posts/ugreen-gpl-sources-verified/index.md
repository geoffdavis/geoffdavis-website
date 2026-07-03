+++
date = '2026-07-03T12:00:00-07:00'
title = "UGREEN Published Their GPL Sources — Here's What's Actually In Them"
description = "Two months ago I documented four GPL-licensed components that UGOS ships without source code and sent UGREEN a formal source request. The source is now public at github.com/ugreen-opensource: the forked btrfs-progs, both ugacl kernel modules, and the patched Samba are all there, and the kernel tree even ships the OEM LED and fan drivers the community had been reverse-engineering. This post verifies what's in the release, what the timeline actually shows, and what's still missing — the patched rsync, the kernel half of the per-user quota system, and the libugacl userspace library."
tags = ['gpl', 'open-source', 'ugreen', 'nas', 'btrfs', 'kernel', 'linux', 'licensing', 'samba']
draft = true
+++

In early May I documented four GPL-licensed components that UGREEN's UGOS ships in modified binary form without corresponding source: a forked `btrfs-progs`, two UGREEN-authored GPL kernel modules (`ugacl_vfs.ko` and `ug_posix_acl.ko`), a patched Samba 4.17.12, and a userspace ACL library (`libugacl.so`) linked into that Samba. I sent UGREEN a formal source request on 2026-05-06, citing GPL-2.0 §3(b) and GPL-3+ §6. They acknowledged it the same day.

The source is now public. [github.com/ugreen-opensource](https://github.com/ugreen-opensource) hosts eight repositories, and I've spent time verifying what's actually in them — not just that repos with the right names exist, but that the code inside matches the binaries UGOS ships.

The short version: this is a real source release, not a compliance fig leaf. Three of my four requested components are fully published, the fourth is partially addressed, and the kernel tree contains working OEM hardware drivers that go beyond anything I asked for. There are still gaps — a patched `rsync` that ships on every unit with no source anywhere, and a per-user quota feature whose userspace half is published but whose kernel half is not — but the overall arc here is UGREEN doing the right thing, and that deserves to be said as plainly as the original criticism was.

Up front, as always: I am a paying UGREEN customer. I bought three NASync DXP units at full retail to run as a three-site replication mesh. The previous post was written as a customer who wanted the source, not a scalp. This one is written as a customer who mostly got it.

**TL;DR** — scorecard against the original post's four findings:

| Component (original finding) | Status | Where |
| --- | --- | --- |
| Forked `btrfs-progs` | **Published** | [`btrfs-progs`](https://github.com/ugreen-opensource/btrfs-progs) — real fork of v6.2 with the ugacl and per-user-quota code |
| Kernel modules `ugacl_vfs.ko` + `ug_posix_acl.ko` | **Published** | [`kernel-6.12`](https://github.com/ugreen-opensource/kernel-6.12): [`fs/kmugacl/`](https://github.com/ugreen-opensource/kernel-6.12/tree/main/fs/kmugacl) and [`fs/posix_acl_ugextend/`](https://github.com/ugreen-opensource/kernel-6.12/tree/main/fs/posix_acl_ugextend) — directory names match the shipped `.ko` paths exactly |
| Patched Samba 4.17.12 | **Published** | [`Samba-4.17.12`](https://github.com/ugreen-opensource/Samba-4.17.12): [`source3/modules/vfs_ugacl.c`](https://github.com/ugreen-opensource/Samba-4.17.12/blob/main/source3/modules/vfs_ugacl.c) + [`vfs_ug_xattr_filter.c`](https://github.com/ugreen-opensource/Samba-4.17.12/blob/main/source3/modules/vfs_ug_xattr_filter.c) |
| `libugacl.so` userspace library | **Not published** | Not in any of the eight repos — and the published Samba source still references it |

Beyond the four asks: the kernel tree ships UGREEN's OEM hardware drivers in [`drivers/ugreen/`](https://github.com/ugreen-opensource/kernel-6.12/tree/main/drivers/ugreen), including the LED-controller driver whose protocol the community spent two years reverse-engineering — the published source confirms the reverse engineering was exactly right — and an IT8613 fan-control driver that fills a real gap for people running third-party OSes on these boxes.

Still missing: the patched `rsync` UGOS ships (breaks standard rsync clients, source published nowhere), the kernel implementation of the per-user btrfs quota system (its userspace tooling and on-disk format are published; the code that writes that format is not), the patched `e2fsprogs`, and `libugacl.so`.

## The Timeline, Honestly

It would make a tidy story to say "I sent a GPL request and five weeks later the source appeared." The repository dates tell a more nuanced story, and the nuance is worth being honest about — some of this predates my request by a long way:

| Repo | Created | Last push | What it is |
| --- | --- | --- | --- |
| `kernel-6.1.27` | 2024-09-28 | 2024-09-28 | Near-stock 6.1 tree — no ugacl, no `drivers/ugreen/` |
| `linux-headers-6.12.30` | 2025-09-19 | 2025-09-19 | Kernel headers package |
| `ugospro-debian12` | 2026-04-02 | 2026-04-03 | Debian rootfs build scripts + package manifest |
| `rk3576_kernel`, `rk3588_kernel` | 2026-04-03 | 2026-04-03 | Rockchip kernels for the ARM models |
| `kernel-6.12` | 2026-04-03 | 2026-04-03 | **The full x86 UGOS kernel — ugacl, drivers, everything** |
| `btrfs-progs` | **2026-06-11** | 2026-06-11 | **The forked btrfs-progs from my request** |
| `Samba-4.17.12` | **2026-06-11** | 2026-06-11 | **The patched Samba from my request** |

So: the GitHub account has existed since August 2024, and the big kernel drop — the repo that answers the kernel-module half of my request — landed on 2026-04-03, a month *before* I sent anything. My original post's search (GitHub included) simply didn't find it; searching for the module names (`ugacl_vfs`, `kmugacl`) returned nothing because GitHub's code search doesn't index these repos (more on that below), and nothing on UGREEN's site linked to the org. I'll own that miss: the kernel source was technically available while I was writing that the kernel source wasn't available. Findability was the failure there, not publication.

The `btrfs-progs` and `Samba-4.17.12` repos are a different matter. Both were created on 2026-06-11 — five weeks after my 2026-05-06 request, six days after the SFC-recommended 30-day response window closed, each as a single squashed commit titled "Initial open source release." I can't prove causation; other customers may have asked too, or this may have been on an internal roadmap. But those are the two repos that cover the userspace components my request enumerated, and they appeared shortly after the request was acknowledged. Whatever the internal mechanics, the observable behavior is: a customer asked for specific GPL sources, and the specific GPL sources showed up.

## Finding 1: btrfs-progs — Published, and It's the Real Thing

The original post identified the shipped `/usr/bin/btrfs` as a ~600 KB-larger fork with `ugacl` strings inside. The [`btrfs-progs`](https://github.com/ugreen-opensource/btrfs-progs) repo is that fork: upstream v6.2 (matching the shipped package's claimed version) plus UGREEN's modifications. I diffed it against upstream v6.2 myself: roughly 4,000 changed lines, which is consistent with a fork substantial enough to produce the size delta in the shipped binary.

Two features account for most of the diff:

**The ugacl send-stream support** — the code behind the `support ugacl(ugreen file 13 permits)` string I extracted from the shipped binary, teaching `btrfs send`/`receive` to carry UGACL xattrs.

**A complete per-user btrfs quota system** that upstream btrfs does not have. Upstream btrfs quotas (qgroups) are per-subvolume; UGREEN built per-*user* accounting on top, and the published source lays out the whole on-disk format in [`kernel-shared/ctree.h`](https://github.com/ugreen-opensource/btrfs-progs/blob/main/kernel-shared/ctree.h):

```c
#define BTRFS_UG_QUOTA_TREE_OBJECTID 208ULL

/* Ugreen usrquota tree */
#define BTRFS_UG_USRQUOTA_TREE_OBJECTID 209ULL

#define BTRFS_USRQUOTA_STATUS_KEY       240
#define BTRFS_USRQUOTA_ROOT_KEY         241
#define BTRFS_USRQUOTA_INFO_KEY         242
#define BTRFS_USRQUOTA_LIMIT_KEY        244
```

Two entirely new btrfs tree object IDs (208 and 209) and a set of item-key types scoped to the new usrquota tree. There's a full command-line interface in [`cmds/usrquota.c`](https://github.com/ugreen-opensource/btrfs-progs/blob/main/cmds/usrquota.c), carrying a `Copyright (C) 2026 Ugreen Inc.` notice and a GPL-2 header. Proper license headers on new files is exactly what you want to see from a first-time corporate GPL release.

The repo history is a single squashed "Initial open source release" commit — you don't get UGREEN's internal development history, and you don't need to for GPL purposes. §3 requires the corresponding source, not the git log.

One thing I have *not* verified: that building this tree reproduces the shipped binary byte-for-byte. Reproducible-build verification is a bigger project (toolchain matching, build flags) and I haven't done it. What I can say is that every identifier I pulled out of the shipped binary with `strings` in the original post — `s_ugacl_magic`, `ug_edit_csum`, the usrquota machinery — has a corresponding definition in this source tree.

## Finding 2: The Kernel Modules — Published, Path-for-Path

This was the finding I was most worried would stay closed, because it's the security-sensitive one: two UGREEN-authored kernel modules hooking the VFS xattr layer and adding a system call.

Both are in [`kernel-6.12`](https://github.com/ugreen-opensource/kernel-6.12), which is exactly version 6.12.30 per its top-level Makefile — matching the `6.12.30+` kernel running on my units. The directory names match the shipped module paths character for character:

- Shipped: `/lib/modules/6.12.30+/kernel/fs/kmugacl/ugacl_vfs.ko` → source: [`fs/kmugacl/`](https://github.com/ugreen-opensource/kernel-6.12/tree/main/fs/kmugacl) (`ugacl_module_lib.c` at ~55 KB, plus the module registration glue)
- Shipped: `/lib/modules/6.12.30+/kernel/fs/posix_acl_ugextend/ug_posix_acl.ko` → source: [`fs/posix_acl_ugextend/`](https://github.com/ugreen-opensource/kernel-6.12/tree/main/fs/posix_acl_ugextend)

The ugacl feature turns out to be bigger than the two loadable modules. It's a build-time kernel feature (`CONFIG_UG_FEAT_FS_ACL_BTRFS` in [`fs/btrfs/Kconfig`](https://github.com/ugreen-opensource/kernel-6.12/blob/main/fs/btrfs/Kconfig)) with core code compiled into the filesystem layer: [`fs/ugacl.c`](https://github.com/ugreen-opensource/kernel-6.12/blob/main/fs/ugacl.c) and `fs/ugacl_api.c` at the VFS level, [`fs/btrfs/ugacl.c`](https://github.com/ugreen-opensource/kernel-6.12/blob/main/fs/btrfs/ugacl.c) for the btrfs integration, and [`fs/ext4/ugacl.c`](https://github.com/ugreen-opensource/kernel-6.12/blob/main/fs/ext4/ugacl.c) for ext4. There's even a `nougacl` mount option wired into `fs/btrfs/super.c`, which suggests a supported way to mount a pool with the ACL layer disabled — potentially useful for recovery scenarios, though I haven't tested it.

For anyone who read my [filesystem lock-in post](/posts/ugreen-ugos-filesystem-lockin/), this tree also answers the two mystery superblock bits documented there:

```c
/* include/uapi/linux/btrfs.h */
#define BTRFS_FEATURE_INCOMPAT_UGACL    (1ULL << 62)

/* fs/ext4/ext4.h */
#define EXT4_FEATURE_INCOMPAT_UGACL    0x20000000
```

Bit 62 in the btrfs `incompat_flags` — the unallocated bit I found set on my own pool — is `BTRFS_FEATURE_INCOMPAT_UGACL`. And ext4 incompat bit 29 — the one upstream `e2fsprogs` reports as the unmountable `FEATURE_I29` — is `EXT4_FEATURE_INCOMPAT_UGACL`. Both formerly-anonymous lock-in flags now have names, definitions, and readable implementations. That doesn't make UGOS pools portable to standard Linux, but it converts "undocumented proprietary format" into "documented source-available format," which is a genuinely different situation for anyone attempting data recovery: the code needed to understand the on-disk format is now public.

Verdict on the original finding: **published**, and more completely than I asked for. The one caveat is that I asked for "the full kernel sources corresponding to the running kernel `6.12.30+`" and got a tree whose version matches — but as with btrfs-progs, I haven't done a reproducible-build comparison against the shipped kernel image.

## Finding 3: Samba — Published

[`Samba-4.17.12`](https://github.com/ugreen-opensource/Samba-4.17.12) contains the patched Samba. The two files the original post identified from binary evidence are both present in the standard in-tree locations:

- [`source3/modules/vfs_ugacl.c`](https://github.com/ugreen-opensource/Samba-4.17.12/blob/main/source3/modules/vfs_ugacl.c) — ~30 KB. The original post inferred "at least 1,215 lines" from `__FILE__:__LINE__` debug strings in the shipped `libsmbd-base-samba4.so.0`; the published file is consistent with that.
- [`source3/modules/vfs_ug_xattr_filter.c`](https://github.com/ugreen-opensource/Samba-4.17.12/blob/main/source3/modules/vfs_ug_xattr_filter.c) — small (~2.5 KB), which explains why the shipped `ug_xattr_filter.so` had almost no strings: there was never much in it. The heavy lifting was always in `vfs_ugacl.c` and the patched core library.
- Bonus wiring I hadn't identified from binaries: btrfs qgroup integration in `source3/lib/` ([`qgroup.h`](https://github.com/ugreen-opensource/Samba-4.17.12/blob/main/source3/lib/qgroup.h), adapted from GPL-2 STRATO btrfs-progs code) — Samba querying quota state directly, presumably for share-size reporting.

Same single-squashed-commit release style as btrfs-progs, same 2026-06-11 date. Verdict: **published**.

## Finding 4: libugacl.so — Not Published

The fourth component from the original post — the userspace `/usr/lib/libugacl.so` whose unstripped debug info leaked its build path (`.../ugacltool/lib/src/ugacl.c`) — is not in any of the eight repositories. I checked repo listings directly rather than trusting search.

The published Samba source makes the dependency concrete: `vfs_ugacl.c` contains a code comment (in Chinese) explaining that ACE ordering is guaranteed by "the `ug_acl_add_ace` function of the libugacl library." So the published GPL-3 Samba code documents its reliance on a library whose source remains closed. My original argument stands: a library linked into `libsmbd-base-samba4.so.0` and required for the shipped Samba to function is part of the Corresponding Source under GPL-3 §6. Publishing the Samba patches while withholding the library they call into is the release's most clear-cut remaining gap.

Verdict: **not published**.

## The Part Nobody Asked For: OEM Hardware Drivers

The most pleasant surprise in the release is [`drivers/ugreen/`](https://github.com/ugreen-opensource/kernel-6.12/tree/main/drivers/ugreen) in the kernel tree — the OEM drivers for the NASync hardware itself, with per-model subdirectories (`dx4700`, `dxp480t`, `dh2600`, ...) and about two dozen source files. Three of them are worth calling out.

### The LED driver: the community reverse engineering was exactly right

UGREEN NAS owners running TrueNAS, Unraid, or plain Debian have relied for two years on [miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller), a community driver built by reverse-engineering the i2c traffic to the LED controller MCU. The community documentation says: HT32F52231 MCU at i2c address `0x3a`, commands sent as fixed-size blocks starting `0xa0 0x01`, an additive checksum over the payload bytes.

[`drivers/ugreen/leds-mcu-28a48.c`](https://github.com/ugreen-opensource/kernel-6.12/blob/main/drivers/ugreen/leds-mcu-28a48.c) is UGREEN's original driver for that hardware, and it confirms every detail:

```c
#define LED_I2C_ADDRESS 0x3a
#define MCU_CHIP_ID    0x5A
/* ... */
u8 data[BLOCK_LEN]={0x00,0x00,0xa0,0x01,0x00,0x00,0x03,0x00,...};
/* additive CRC computed over bytes 2..10 */
```

Thirteen-byte command blocks, `a0 01` opcode prefix, additive checksum, chip-ID register `0x5A` returning `0xC5B2`, sysfs attribute groups literally named `ht32f52231_attrs`. The community got the protocol byte-for-byte right, and now anyone can check their work against the vendor's own source. This is one of the quiet benefits of GPL compliance that rarely gets mentioned: it retroactively validates (or corrects) the community's reverse-engineering work, and gives third-party-OS driver maintainers an authoritative reference going forward. (There's also a newer [`leds-mcu.c`](https://github.com/ugreen-opensource/kernel-6.12/blob/main/drivers/ugreen/leds-mcu.c) variant that selects behavior by DMI product name — `DXP2800`, `DXP6800`, `DXP4800 GT` and friends — for the current model line.)

### The fan driver: real value for third-party OS users

[`drivers/ugreen/ug_it86x-sio.c`](https://github.com/ugreen-opensource/kernel-6.12/blob/main/drivers/ugreen/ug_it86x-sio.c) is a Super-I/O driver for the ITE IT8613 chip that handles fan control on several NASync models. It exposes fan RPM and PWM control at `/proc/it86/fan` and — interestingly — AC-power-loss boot behavior at `/proc/it86/startup`, with register comments citing the IT8613 datasheet.

This matters more than it sounds: the mainline Linux `it87` hwmon driver has no IT8613 support in any kernel version — I checked the upstream chip tables. So if you run TrueNAS or vanilla Debian on an IT8613-equipped NASync, you have had no in-kernel fan monitoring at all. This driver closes that gap, and it isn't just archaeology: I built `ug_it86x-sio.c` unpatched against a 6.18 kernel and it compiles cleanly. It's `/proc`-interface style rather than modern hwmon sysfs, so it's not mainline-ready as-is, but it's a working reference with the register map spelled out.

### The watchdog: reassuringly boring

I also compared the vendor tree's [`drivers/watchdog/it87_wdt.c`](https://github.com/ugreen-opensource/kernel-6.12/blob/main/drivers/watchdog/it87_wdt.c) and [`drivers/hwmon/it87.c`](https://github.com/ugreen-opensource/kernel-6.12/blob/main/drivers/hwmon/it87.c) against upstream 6.12.30: the watchdog driver differs by a single removed log line, and the hwmon driver is byte-identical. UGREEN's hardware watchdog is driven by the stock mainline driver, not secret sauce. When you're auditing a vendor kernel, "identical to upstream" is the best possible finding for the parts that were already upstream.

## License Hygiene

Small notes for anyone assessing the release's compliance quality:

- **The kernel repo's actual license is correct.** The `COPYING` file in `kernel-6.12` is the standard kernel license: `GPL-2.0 WITH Linux-syscall-note`, with the `LICENSES/` directory intact. GitHub's automated license detection labels the repo "GPL-3.0" on the org page — that's GitHub's classifier being confused, not UGREEN misdeclaring anything. Read `COPYING`, not the sidebar badge.
- **New files carry SPDX headers and copyright notices.** `fs/btrfs/ugacl.h` opens with `SPDX-License-Identifier: GPL-2.0` and a UGREEN copyright line (charmingly dated "2000-2021" — someone copy-pasted a template from a company older than UGREEN's NAS division). The btrfs-progs and Samba additions carry proper GPL-2 boilerplate.
- **One cosmetic header slip:** `ug_it86x-sio.c` opens with a copy-pasted "Intel MIC Platform Software Stack" GPL header, complete with Intel's 2015 copyright. The license terms are fine (it's a GPL-2 header); the attribution is just template debris. Worth fixing, not worth complaining about.
- **`ugospro-debian12` is a compliance shell, in the honest sense.** It's the rootfs build scripts, a package manifest, a `BUILD_SOURCE.md` pointing at the Debian archives for stock package sources, and a `common-licenses` directory. That's a legitimate way to handle the hundreds of *unmodified* Debian packages in UGOS. It does not, and cannot, cover the modified ones — which brings us to what's still missing.

## What's Still Missing

Credit given, four gaps remain. In descending order of how much they matter:

**1. The patched rsync.** UGOS ships a modified `/usr/bin/rsync` with a path-allowlist: standard rsync clients talking to it fail with `invalid path` errors thrown from `clientserver.c(2089)` — a failure mode I've hit directly, and which required working around with a containerized stock rsync. rsync is GPL-3. The source is in none of the eight repos, and `ugospro-debian12`'s manifest lists plain `rsync` as if the stock Debian package were what ships. Given that UGOS's own Sync & Backup feature is rsync-based, this is not an obscure component — it's arguably the most user-facing modified binary on the system, and it's the clearest remaining §6 item.

**2. The kernel half of usrquota.** The published btrfs-progs defines the complete on-disk format for the per-user quota system — trees 208 and 209, the item keys, the ioctls, a full CLI. But the format has to be *written* by the kernel, and the published `kernel-6.12` tree contains no usrquota implementation: no usrquota file in `fs/btrfs/`, no references in `ctree.h` or `qgroup.c`, nothing in the uapi headers. Same for `kernel-6.1.27`. The userspace half of a feature was published without the kernel half that makes it function — likely meaning the shipping UGOS kernel has diverged from the April source drop, which is the standard treadmill problem of point-in-time GPL releases. The fix is releasing the tree corresponding to the *current* firmware, and doing so on an ongoing basis.

**3. The patched e2fsprogs.** UGOS's `dumpe2fs` knows the `ugacl` ext4 feature by name; upstream e2fsprogs doesn't. The kernel side of ext4 ugacl is published; the modified e2fsprogs is not. Smaller than the rsync gap, same shape.

**4. libugacl.so**, covered above — referenced by the published GPL-3 Samba code, source still closed.

A meta-issue that costs UGREEN most of the goodwill this release should earn them: **findability**. Nothing on UGREEN's downloads page or help center links to github.com/ugreen-opensource (as of this writing). GitHub's code search doesn't index the large repos — searching GitHub for `ugacl_vfs` or `kmugacl` returns zero hits *even now*, with the source sitting right there in a public repo. I verified this directly: code-search queries scoped to `kernel-6.12` return nothing for strings that appear in dozens of its files. That's how my original post managed to miss a kernel tree that had been public for a month. A single link — "Open Source" in the downloads page footer, pointing at the org — plus a `README` in each repo mapping repos to firmware versions would fix this completely.

## Scorecard

| Original ask | Verdict |
| --- | --- |
| btrfs-progs fork | ✅ Published, real, properly licensed |
| `ugacl_vfs.ko` + `ug_posix_acl.ko` sources | ✅ Published, path-for-path |
| Full kernel tree for `6.12.30+` | ✅ Published (version matches; build reproducibility unverified) |
| Samba 4.17.12 patches incl. `vfs_ugacl.c` | ✅ Published |
| `libugacl.so` | ❌ Not published |
| *(Not in the original ask)* patched rsync | ❌ Not published anywhere |
| *(Not in the original ask)* OEM hardware drivers | ✅ Published, and genuinely useful |

When I wrote the original post I said the fix would cost UGREEN very little and earn them real goodwill. They've now done most of the fix. The engineering content of this release is better than the average embedded vendor's GPL drop: real forks with real history behind them (even if squashed), correct licenses, matching directory structures, and hardware drivers nobody was legally forcing them to organize this neatly. Whoever did the work inside UGREEN did it properly.

So, credit where due: if you're a UGREEN customer who emailed a source request after reading the original post — thank you; whatever the internal causality was, the observable system works. And if you're UGREEN: publish the rsync source, refresh the kernel tree to match current firmware, release `libugacl` and the e2fsprogs patches, and put a link to the GitHub org somewhere a customer can find it. Then this series gets its final post, and it'll be a short, happy one.

## Verify It Yourself

Everything above about repo contents is checkable from any machine with the GitHub CLI — no NAS required. A few starting points:

```sh
# Repo list with creation dates (the timeline)
gh api users/ugreen-opensource/repos \
  --jq '.[] | {name, created_at, pushed_at}'

# The kernel-module source directories match the shipped .ko paths
gh api repos/ugreen-opensource/kernel-6.12/contents/fs/kmugacl \
  --jq '.[].name'
gh api repos/ugreen-opensource/kernel-6.12/contents/fs/posix_acl_ugextend \
  --jq '.[].name'

# The formerly-mysterious btrfs incompat bit 62, now with a name
gh api -H "Accept: application/vnd.github.raw" \
  repos/ugreen-opensource/kernel-6.12/contents/include/uapi/linux/btrfs.h \
  | grep INCOMPAT_UGACL

# No usrquota in the published kernel's btrfs (the missing kernel half) —
# expect no output; compare against the same grep on the btrfs-progs repo
gh api repos/ugreen-opensource/kernel-6.12/contents/fs/btrfs \
  --jq '.[].name' | grep -i usrquota
gh api repos/ugreen-opensource/btrfs-progs/contents/cmds \
  --jq '.[].name' | grep -i usrquota
```

One practical warning if you go digging: use the `contents` API for directory listings, as above. GitHub's recursive git-trees API silently truncates on repos the size of a kernel tree, and will happily tell you a file doesn't exist when it does — the same class of false negative that GitHub code search produces on these repos. Ask me how I know.
