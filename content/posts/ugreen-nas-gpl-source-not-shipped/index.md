+++
date = '2026-05-06T16:00:00-07:00'
title = 'UGREEN NAS Ships GPL-Licensed Btrfs Patches Without Source'
description = "UGOS modifies btrfs-progs and adds two GPL kernel modules to implement Windows-style ACLs, but ships none of the source code and provides no §3(b) written offer. Here is the on-disk evidence and how to file your own GPL source request."
tags = ['gpl', 'open-source', 'ugreen', 'nas', 'btrfs', 'kernel', 'linux', 'licensing']
draft = true
+++

> **Update 2026-05-08:** I sent the source request to UGREEN customer support on 2026-05-06. UGREEN acknowledged the request on the same day and indicated they are consulting with their internal development and responsible teams. This post will remain unpublished pending their substantive response. The 30-day SFC-recommended response window runs through 2026-06-05.
>
> **Update 2026-07-03:** UGREEN has since published UGOS Pro's GPL sources at [github.com/ugreen-opensource](https://github.com/ugreen-opensource). I went through the release module by module — the forked `btrfs-progs`, both ugacl kernel modules, and the patched Samba are all there, and the kernel tree even ships the OEM LED and fan drivers the community had been reverse-engineering — along with what the timeline actually shows and what's *still* missing. The full verification is a follow-up post: [UGREEN Published Their GPL Sources — Here's What's Actually In Them]({{< relref "ugreen-gpl-sources-verified" >}}).

UGREEN's NASync line ships a NAS operating system called UGOS, based on Debian Bookworm, with proprietary additions to support their app store, sharing UI, and a Windows-style Access Control List system layered on top of POSIX ACLs.

Some of those proprietary additions are not actually proprietary. They are GPL-licensed modifications to GPL-licensed upstream software. UGREEN ships the modified binaries on every NAS they sell, but does not ship the source code, does not include a written offer for the source code, and — on the unit I inspected — has even removed the upstream license file from the on-disk filesystem.

This post walks through the on-disk evidence, what the GPL actually requires, what UGREEN actually provides, and what you can do about it as a customer.

Up front: I am a paying UGREEN customer. I bought three NASync DXP units at full retail to run as a three-site replication mesh, and I'm broadly happy with the hardware. I'm writing this as a customer who would like to keep recommending these devices to other people, not as a competitor or a critic looking to score points. The compliance gap below is fixable, the fix costs UGREEN very little, and I would much rather see them publish the source than have to keep working around a problem this post documents.

**TL;DR**: At least four shipped components on UGOS are GPL'd, modified, and shipped without source:

- **`btrfs-progs`** (`/usr/bin/btrfs` and siblings) — UGREEN-forked, ~600 KB larger than the stock Debian package, MD5-mismatched in `dpkg --verify`, with internal strings like `support ugacl(ugreen file 13 permits)`. GPL-2.0-only.
- **Two GPL-declared kernel modules** — `ugacl_vfs.ko` and `ug_posix_acl.ko` — that hook the VFS xattr layer and add a new system call. GPL-2.0 (declared by `MODULE_LICENSE("GPL")`).
- **Samba 4.17.12** — the entire `samba-vfs-modules` package is rebuilt, and `libsmbd-base-samba4.so.0` is patched with a ~1200-line `source3/modules/vfs_ugacl.c` plus UGREEN-specific config parameters. GPL-3+.
- **`/usr/lib/libugacl.so`** — a companion userspace ACL library, *unstripped*, whose debug-info strings reveal the absolute build-server path of the source: `/data2/wanghuanchun/dev/ugacltool/ugacltool/lib/src/ugacl.c`. Linked into GPL-3 Samba; aggregation rules apply.

None of the source code for any of this is published on UGREEN's downloads page, in their help center, on GitHub, or in any community-known location. Multiple `/usr/share/doc/<pkg>/copyright` files — where Debian records upstream licenses and source attribution — are deleted. This appears to violate GPL-2.0 §3 and §1 for the btrfs and kernel components, and GPL-3+ §6 and §4 for the Samba components.

I am not a lawyer. None of this is legal advice. The recommendations below are what I plan to do as a customer.

## What I Was Actually Looking For

I was not auditing UGREEN's GPL compliance. I was trying to fix a backup pipeline.

As mentioned at the top of this post, I bought three NASync DXP units and run them as a three-site mesh, replicating snapshots between them with [`btrbk`](https://github.com/digint/btrbk) — a tool that wraps `btrfs send | btrfs receive` to do incremental cross-host snapshot replication. The receivers run inside Alpine containers on the destination NAS.

Some of the cross-NAS replication runs were aborting mid-stream. The error always looked like this:

```text
ERROR: lsetxattr "system.ugacl_self" = ...: Not supported
```

`system.ugacl_self` is an extended attribute that UGREEN attaches to every file managed through their UI. It is not a Linux kernel xattr. It is not POSIX. It is not part of any standard. It is UGREEN's own thing, stored in the `system.*` xattr namespace, which is the namespace reserved by the Linux kernel for in-kernel use.

Standard Linux kernels reject `lsetxattr()` calls into the `system.*` namespace unless a kernel subsystem has explicitly registered a handler for the specific name. UGOS apparently *does* register such a handler — but only for processes in certain mount namespaces, which excludes containers. So when my container's `btrfs receive` tries to apply `system.ugacl_self` records that arrived in the send stream, the kernel says no.

To diagnose this, I had to understand how UGOS handles `system.ugacl_self` on the host side. That is what led me down the path that turned into this post.

## On-Disk Evidence

These commands run on a UGOS NAS as a user with `sudo` access. I ran them on a NASync DXP with UGOS Pro firmware, kernel `6.12.30+`, on 2026-05-06. Other models or firmware versions may differ.

### The btrfs binary is modified post-package-install

```text
$ dpkg --verify btrfs-progs
??5??????   /bin/btrfs
??5??????   /bin/btrfs-convert
??5??????   /bin/btrfs-find-root
??5??????   /bin/btrfs-image
??5??????   /bin/btrfs-map-logical
??5??????   /bin/btrfs-select-super
??5??????   /bin/btrfstune
missing     /sbin/fsck.btrfs
missing     /sbin/mkfs.btrfs
missing     /usr/share/doc/btrfs-progs
missing     /usr/share/doc/btrfs-progs/copyright
missing     /usr/share/doc/btrfs-progs/changelog.Debian.gz
missing     /usr/share/doc/btrfs-progs/changelog.gz
missing     /usr/share/man/man8/btrfs-receive.8.gz
... (most man pages also missing) ...
```

The `5` in the verify flags is `dpkg(1)`'s code for "MD5 sum differs" — the file on disk is not the file dpkg installed. Every btrfs binary differs. The package metadata still claims version `6.2-1`, but the actual on-disk binary has been replaced.

```text
$ ls -la /usr/bin/btrfs
-rwxr-xr-x 1 root root 5303008 Dec 23 05:24 /usr/bin/btrfs

$ apt show btrfs-progs 2>&1 | grep Installed-Size
Installed-Size: 4,590 kB
```

The actual binary is 5,303,008 bytes — about 600 KB larger than the stock Debian package's reported install size. Build timestamp is 2025-12-23, vs the package's original install date of 2023-06-14 (visible in `/var/log/dpkg.log*`). The replacement happened roughly two and a half years after the original install, presumably via a UGOS firmware update.

### The patched btrfs binary contains UGREEN-specific code

```text
$ strings /usr/bin/btrfs | grep -iE "ugacl|ug_edit|magic" | sort -u
    error ugacl magic: 0x%0X
i_magic_not_ugacl
s_ugacl_magic
support ugacl(ugreen file 13 permits)
ug_edit_csum
ugacl
```

`support ugacl(ugreen file 13 permits)` is the smoking gun. In the btrfs send-stream protocol (`fs/btrfs/send.h` in the kernel tree), command type 13 is `BTRFS_SEND_C_SET_XATTR`. The string says, in not-quite-grammatical English, that the patched btrfs has been taught how to handle UGACL xattrs at the SET_XATTR command level. `ug_edit_csum` strongly implies the patch also adjusts btrfs's per-record CRCs to accommodate the UGREEN-format xattr payloads.

This is a real fork of btrfs-progs, not a thin wrapper. The strings reference internal-sounding C identifiers (`s_ugacl_magic`, `i_magic_not_ugacl`) consistent with patches across multiple translation units.

### Two UGREEN-authored kernel modules, both declared GPL

```text
$ lsmod | grep -E "ugacl|ug_posix"
ug_posix_acl           12288  0
ugacl_vfs              40960  2

$ find /lib/modules -name "ugacl*" -o -name "ug_posix_acl*"
/lib/modules/6.12.30+/kernel/fs/kmugacl/ugacl_vfs.ko
/lib/modules/6.12.30+/kernel/fs/posix_acl_ugextend/ug_posix_acl.ko

$ strings /lib/modules/6.12.30+/kernel/fs/kmugacl/ugacl_vfs.ko \
    | grep -E "description|author|license|name" | head
description=Add Windows ACL System Call Support
author=Ugreen Inc.
license=GPL
name=ugacl_vfs
```

Three things here matter:

1. **The modules are loaded and in active use.** `ugacl_vfs` has a refcount of 2, meaning two kernel subsystems currently depend on it.
2. **They declare themselves GPL.** That is not a marketing claim. Module `MODULE_LICENSE("GPL")` is what allows the module to use GPL-only kernel symbols — without that declaration, the module loader refuses the symbol exports it needs to function. UGREEN had to declare GPL to make their module work.
3. **They are explicitly UGREEN-authored.** `author=Ugreen Inc.` Not a fork of an existing module; original code by UGREEN, against the kernel's GPL'd internal interfaces, by their own attestation.

The exported function names tell you what these modules do:

```text
$ strings /lib/modules/6.12.30+/kernel/fs/kmugacl/ugacl_vfs.ko \
    | grep -E "^ugacl_|^posixacl_|__vfs_" | sort -u
__vfs_getxattr
__vfs_removexattr_locked
__vfs_setxattr_locked
posixacl_convert_to_ugacl
ugacl_alloc
ugacl_clone
ugacl_from_xattr
ugacl_get_archive_bits
ugacl_init_acl
ugacl_realloc
ugacl_syscall_op
ugacl_to_xattr
ugacl_vfs
ugacl_xattr_get
```

`ugacl_vfs.ko` hooks the kernel's three core extended-attribute entry points (`__vfs_setxattr_locked`, `__vfs_getxattr`, `__vfs_removexattr_locked`) and adds an entirely new system call (`ugacl_syscall_op`). It converts between POSIX ACLs and UGACL format, and inspects an "archive bit" — Windows-NTFS-derived terminology that confirms the module's stated purpose of grafting Windows ACL semantics onto Linux's xattr layer.

This is non-trivial kernel code touching security-relevant interfaces. It is the kind of code where source review matters.

### Samba is patched the same way, on a stricter license

A kernel ACL implementation is only useful if user-facing protocols know how to surface it. SMB is the obvious consumer — it is how Windows and macOS clients see the NAS's permission model. So I checked Samba next, and found the same compliance gap on a more restrictive license.

```text
$ smbd -V
Version 4.17.12-Debian

$ dpkg -s samba | grep Version
Version: 2:4.17.12+dfsg-0+deb12u3

$ dpkg --verify samba-vfs-modules | head
??5??????   /usr/lib/x86_64-linux-gnu/samba/vfs/acl_tdb.so
??5??????   /usr/lib/x86_64-linux-gnu/samba/vfs/acl_xattr.so
??5??????   /usr/lib/x86_64-linux-gnu/samba/vfs/aio_fork.so
??5??????   /usr/lib/x86_64-linux-gnu/samba/vfs/btrfs.so
... (every single VFS module shows MD5 mismatch) ...

$ ls /usr/share/doc/samba/copyright
ls: cannot access '/usr/share/doc/samba/copyright': No such file or directory
```

Same pattern as btrfs-progs: every binary modified post-package-install, the `/usr/share/doc/samba/copyright` file deleted. Same `Dec 23 05:24` build mtime on the static binaries, indicating the same UGREEN build batch.

There is one new VFS module that does not exist in stock Samba:

```text
$ ls /usr/lib/x86_64-linux-gnu/samba/vfs/ | grep -i ug
ug_xattr_filter.so
```

`ug_xattr_filter.so` is heavily stripped — it has almost no useful strings beyond the standard Samba module entry-point symbol. But the patches in the core Samba shared library are not stripped, and they tell most of the story:

```text
$ strings /usr/lib/x86_64-linux-gnu/samba/libsmbd-base-samba4.so.0 \
    | grep -iE "ugacl|ugreen" | sort -u | head -10
fget_nt_acl(real_path:%s, stream:%s) ugacl_agent_acl fail, ret:%d
heshaobo ugacl_fchmod(real_path:%s, base_name:%s)
heshaobo ugacl_fchmod ugacl mode skip fchmod
libugacl.so
lp_ugreen_cpu_affinity
smb_register_vfs vfs_ugacl failed
smb_ugacl_get_archive_bit
smbacl4_set_ugacl_archive_bit
../../source3/modules/vfs_ugacl.c
../../source3/modules/vfs_ugacl.c:1156
... (32 distinct line-number references, max line 1215) ...
```

Three things this tells us:

1. **The Samba source file is `source3/modules/vfs_ugacl.c`** — a file in the standard Samba source-tree layout (`source3/modules/` is where VFS modules live upstream), at least 1,215 lines long. This is a substantial fork, not a small patch.
2. **Internally the module registers as `vfs_ugacl`; externally it ships as `ug_xattr_filter.so`.** The internal name appears in `smb_register_vfs vfs_ugacl failed` — the name passed to Samba's module-registration function — while the on-disk filename is `ug_xattr_filter.so`. The two names do not match.
3. **UGREEN added their own loadparm config keys**: `lp_ugreen_cpu_affinity` and `lp_edit_ugacl` (the latter visible in `libsmbconf.so`). These are Samba `smb.conf` parameters UGREEN created. They are not in upstream Samba.

The `heshaobo` prefix on two of the debug strings is a developer attribution that survived stripping — debug-log macros that prepend a developer name to function entry/exit traces are common in C codebases and tend to leak into shipped binaries. The strings appear here as they appear in the binary; any UGOS owner can extract the same output with `strings`. The point is not the individual but the fact that the source file `vfs_ugacl.c` has identifiable in-tree authorship, which is one more indicator that the source exists in a producible form.

`smb.conf` confirms `ug_xattr_filter` is wired into every share UGOS exports:

```text
$ sudo testparm -s 2>&1 | grep "vfs object"
    full_audit:prefix     = ugreen_syslog|%u|%I
    vfs objects = catia fruit full_audit streams_xattr ug_xattr_filter
    vfs objects = catia fruit full_audit recycle streams_xattr ug_xattr_filter
    ... (14 share definitions, all using ug_xattr_filter) ...
```

This is not optional or dormant code. Every SMB connection on the NAS goes through UGREEN's modified Samba.

### libugacl.so: source path leaked in debug info

There is one more component, and this is where the evidence stops being merely *strong* and becomes *dispositive*. UGREEN ships a userspace ACL library at `/usr/lib/libugacl.so` that — unlike everything else discussed above — was not stripped of debug information:

```text
$ file /usr/lib/libugacl.so
/usr/lib/libugacl.so: ELF 64-bit LSB shared object, x86-64,
  version 1 (SYSV), dynamically linked,
  BuildID[sha1]=87c06f8a88522da2e35aac9378789f7377c61d8e,
  with debug_info, not stripped

$ strings /usr/lib/libugacl.so | grep -E "^/[a-z]"
/data2/wanghuanchun/dev/ugacltool/ugacltool/build/lib
/data2/wanghuanchun/dev/ugacltool/ugacltool/lib/include
/data2/wanghuanchun/dev/ugacltool/ugacltool/lib/src
/data2/wanghuanchun/dev/ugacltool/ugacltool/lib/src/../include
/data2/wanghuanchun/dev/ugacltool/ugacltool/lib/src/ugacl.c
/data2/wanghuanchun/dev/ugacltool/ugacltool/lib/src/walk_tree.c
```

These are absolute build-server paths embedded by the compiler when debug info is enabled. They tell you:

- The source code is named `ugacltool`
- It lives at `/data2/wanghuanchun/dev/ugacltool/` on UGREEN's build server, in a developer's home directory
- The build output (`build/`), public headers (`lib/include`), and source files (`lib/src/ugacl.c`, `lib/src/walk_tree.c`) are organized as a normal CMake-style C project
- The library is intentionally consumed by the modified Samba: `libsmbd-base-samba4.so.0` references `libugacl.so` by name

GPL-3+ §6 ("Conveying Non-Source Forms") requires UGREEN to make the *Corresponding Source* available for any work they convey. The Corresponding Source is defined in §1 to include "all the source code needed to generate, install, and ... run the object code and to modify the work, including scripts to control those activities." A library that is linked into a GPL-3 program (`libsmbd-base-samba4.so.0`) and required for that program to function is part of the Corresponding Source.

The library is unstripped enough that we can enumerate the public functions:

```text
$ nm -D /usr/lib/libugacl.so | grep " T "
... convert_posixacl_to_ugacl
... default_posixacl_to_ugacl
... do_convert_posixacl_to_ugacl_pre
... do_convert_posxiacl_to_ugacl
... cmp_ugacl
... find_ugacl_duplicate_item_entry
... alloc_convert_progress
... alloc_perm_files
... debug_thread_func
```

This is purely a userspace library doing POSIX-ACL ↔ UGACL conversion. It cannot be claimed as a kernel-only component. As a library linked into GPL-3 Samba, its source is part of the Corresponding Source that GPL-3+ §6 requires UGREEN to make available.

## What the GPL Requires

Both `btrfs-progs` and the Linux kernel are licensed under [GPL-2.0-only](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html). The relevant clauses are short and quotable:

**§1** (preservation of copyright notices):
> You may copy and distribute verbatim copies of the Program's source code as you receive it, in any medium, provided that you conspicuously and appropriately publish on each copy an appropriate copyright notice and disclaimer of warranty; **keep intact all the notices that refer to this License and to the absence of any warranty**; and give any other recipients of the Program a copy of this License along with the Program.

**§3** (binary distribution requires source):
> You may copy and distribute the Program ... in object code or executable form under the terms of Sections 1 and 2 above provided that you also do one of the following:
>
> (a) Accompany it with the complete corresponding machine-readable source code, which must be distributed under the terms of Sections 1 and 2 above on a medium customarily used for software interchange; or,
>
> (b) Accompany it with a written offer, valid for at least three years, to give any third party, for a charge no more than your cost of physically performing source distribution, a complete machine-readable copy of the corresponding source code ...

GPL §3 enumerates the acceptable forms of binary distribution. Shipping a modified binary without (a) the source, (b) a written offer for the source, or (c) — a third option only available to non-commercial redistributors of an existing §3(b) offer — is not a permitted form. There is no §3(d).

GPL §1 requires preservation of copyright and license notices. Deleting `/usr/share/doc/btrfs-progs/copyright`, the file Debian uses to record the btrfs-progs upstream copyright and license terms on every install, is a §1 issue independent of the §3 source-distribution issue.

## What UGREEN Actually Provides

I checked the publicly available UGREEN resources for any source distribution.

**[UGREEN Downloads Center](https://nas.ugreen.com/pages/downloads)**: Firmware images, client apps for the NAS apps, Windows/Mac/iOS/Android desktop apps, peripheral drivers, UPS firmware, and product PDFs. No source code section. No GPL link. No reference to open-source compliance.

**[UGREEN Help / Service](https://nas.ugreen.com/pages/service)**: Warranty terms, contact info, FAQs. No source code section. No GPL link.

**Search**: I searched GitHub, Google, and DuckDuckGo for `ugacl_vfs`, `kmugacl`, `ug_posix_acl`, "ugreen open source", "ugreen GPL", and several variations. Community projects exist — [TheLinuxGuy/ugreen-nas](https://github.com/TheLinuxGuy/ugreen-nas) for community notes, [vzvl/ugos-community-guide](https://github.com/vzvl/ugos-community-guide), [ln-12/UGOS_scripts](https://github.com/ln-12/UGOS_scripts), and [mzcls/ugreen_dx4600_leds_controller](https://github.com/mzcls/ugreen_dx4600_leds_controller) for the reverse-engineered LED kernel module — but none of them are *UGREEN-published* source for the patches I'm looking for. No UGREEN source release is publicly findable.

**On the NAS itself**: `/usr/src` contains only NVIDIA's Nsight samples. There is no `ugacl` directory, no buildroot reference, no debug-info path strings in the shipped binaries that would point at a build server. No CD or paper offer ships with the device. There is no on-NAS document at any obvious path that mentions an offer to provide source.

**Apt**: `/etc/apt/sources.list.d/` points only at stock Debian Bookworm + NVIDIA CUDA repos. UGREEN does not ship a custom apt repository, so there is no `apt-get source ugacl-vfs` path either.

The cumulative absence is the violation. GPL §3 does not require the source to be on the device; it requires the source to be *available* through one of the enumerated channels. None of those channels appear to be active.

## What I Plan To Do

I am sending a formal source request to UGREEN, citing GPL-2.0 §3(b) and GPL-3+ §6, and asking for the source code to:

- The modifications to `btrfs-progs` shipping as `/usr/bin/btrfs` (build date 2025-12-23) on UGOS Pro
- The kernel module `ugacl_vfs.ko` (file path `/lib/modules/6.12.30+/kernel/fs/kmugacl/ugacl_vfs.ko`)
- The kernel module `ug_posix_acl.ko` (file path `/lib/modules/6.12.30+/kernel/fs/posix_acl_ugextend/ug_posix_acl.ko`)
- The full kernel sources corresponding to the running kernel `6.12.30+`, since the kernel itself is GPL'd and the `+` suffix indicates a custom build
- The Samba modifications shipping in `samba-vfs-modules` (every VFS module is rebuilt) and `libsmbd-base-samba4.so.0` (patched with `source3/modules/vfs_ugacl.c` and the loadparm parameters `lp_ugreen_cpu_affinity` and `lp_edit_ugacl`), corresponding to Samba version `4.17.12-Debian`
- The Samba VFS module shipping as `/usr/lib/x86_64-linux-gnu/samba/vfs/ug_xattr_filter.so` (registered internally as `vfs_ugacl`)
- The userspace library shipping as `/usr/lib/libugacl.so`, which is linked into the modified Samba and whose Corresponding Source is required under GPL-3+ §6

The contact address is `service.nas@ugreen.com`. The other documented support channels (the technical-support portal at `web.ugnas.com`, phone numbers in the help center) may also accept the request.

If UGREEN responds with the source, this post will be updated. If they refuse or do not respond within a reasonable window — GPL doesn't define the window precisely but consensus is that "weeks, not months" is reasonable — the next step is the [Software Freedom Conservancy](https://sfconservancy.org/), which accepts intake on GPL violations and has a long history of getting embedded vendors to comply.

## What You Can Do

If you own a UGREEN NAS, you have standing to make the same request. You received a binary; the GPL gives you the right to receive the corresponding source. UGREEN's burden is not your burden — you don't need to prove the violation, you just need to ask.

A brief, polite, specific email is more effective than legal threats. Something like:

> Hello,
>
> I own a UGREEN [model] running UGOS [version]. I would like to request the source code for the modifications you have made to GPL-licensed software shipping on this device, as required by GPL-2.0 §3(b) and GPL-3+ §6. Specifically:
>
> - The modifications to `btrfs-progs` distributed as `/usr/bin/btrfs` and its sibling binaries
> - The kernel modules `ugacl_vfs.ko` and `ug_posix_acl.ko`
> - The kernel sources corresponding to the running version (e.g. `6.12.30+` on my unit)
> - The Samba modifications shipping in the `samba-vfs-modules` package and in `libsmbd-base-samba4.so.0`, including the source for `source3/modules/vfs_ugacl.c` and the loadparm parameters `lp_ugreen_cpu_affinity` and `lp_edit_ugacl`
> - The userspace library `/usr/lib/libugacl.so`, which is linked into the modified Samba and is therefore part of the Corresponding Source under GPL-3+
>
> Please send instructions for receiving this source, or a download link.
>
> Thank you.

If enough customers ask, the request becomes a process problem they have to solve, rather than a per-customer exception they can ignore.

## Why This Matters Beyond Principle

There is a practical reason customers should care about this beyond the philosophical one.

UGREEN's `system.ugacl_self` xattr is the metadata that controls who can see your photos in the Photos app, who can read your shared folders over SMB, and how the NAS UI applies per-user access. It is security-relevant code, written by UGREEN, against kernel-internal interfaces, with no public review.

That is a code path you cannot audit, cannot verify, and cannot fix. If there is a vulnerability in `ugacl_vfs.ko` — say, a missing namespace check that lets a containerized process bypass UGOS's sharing rules — nobody outside UGREEN can find or patch it without first reverse-engineering the binary. GPL exists to prevent this. Hidden kernel security code in a device sold to consumers is exactly the case the FSF was thinking about when they wrote §3.

There is also a practical-for-me reason: with the source, I could write a btrbk-friendly upstream patch that lets `btrfs receive` skip unknown `system.*` xattrs gracefully, instead of aborting the whole stream. Today I work around the issue with a [send-stream filter](https://github.com/geoffdavis/ugreen-nas-compose/pull/71) that drops `system.ugacl_self` records before they reach the receiver. That works for my disaster-recovery model, but a proper upstream fix would help every other vendor of every other NAS that decides to put a custom xattr in the `system.*` namespace.

## How to Verify This Yourself

Run these on your own UGOS NAS over SSH (no root needed for most of them):

```sh
# Confirm the btrfs binary is modified post-install
dpkg --verify btrfs-progs

# Confirm the binary differs from the stock package size
ls -la /usr/bin/btrfs
apt show btrfs-progs 2>&1 | grep Installed-Size

# Confirm the GPL/copyright file is missing
ls /usr/share/doc/btrfs-progs/ 2>&1

# Inspect the patched binary's UGACL strings
strings /usr/bin/btrfs | grep -iE "ugacl|ug_edit|magic" | sort -u

# Confirm the kernel modules exist and declare GPL
lsmod | grep -E "ugacl|ug_posix"
find /lib/modules -name "ugacl*" -o -name "ug_posix_acl*"
strings /lib/modules/$(uname -r)/kernel/fs/kmugacl/ugacl_vfs.ko \
  | grep -E "description|author|license|name="
```

If your output looks substantially the same as mine, your unit is in the same state.

## Summary

UGREEN appears to be shipping GPL-modified `btrfs-progs` and at least two GPL kernel modules without source distribution and without a §3(b) written offer, and has removed the on-disk license notice that GPL §1 requires preserving. None of this is malicious — it is most likely a process oversight by an embedded device manufacturer that grew quickly and has not yet built out a GPL compliance pipeline. But process oversight is exactly what the GPL's source-distribution mechanism is designed to surface, and the fix is straightforward: publish the modified source.

I'm hopeful UGREEN responds well. They have built a genuinely good NAS and the tooling around UGOS is capable. Closing this gap would cost them very little and earn them real goodwill in the homelab and self-hoster communities — both populations that disproportionately influence the recommendations that drive consumer NAS purchases.

If you've made a similar request and gotten a response — positive or negative — I'd love to hear about it. Email me at the address listed at the bottom of any page on this site.
