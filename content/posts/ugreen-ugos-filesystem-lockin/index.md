+++
date = '2026-05-07T22:30:00-07:00'
title = "UGREEN UGOS Locks Your Data In: ext4 FEATURE_I29, Modified BTRFS, and Filesystem Surprises"
description = "UGOS modifies the on-disk filesystem layer in three different ways that affect data portability and operational tooling. UGOS-formatted ext4 volumes refuse to mount on standard Linux because of an undocumented `FEATURE_I29` feature flag. UGOS-formatted btrfs volumes are similarly modified. UGOS writes a kernel-namespace xattr (`system.ugacl_self`) that breaks `btrfs send | btrfs receive` replication. And the bind-mount FS-shim presents the same inode with different mode bits depending on which namespace is reading it. The aggregate effect is a NAS where your data is more UGOS-dependent than the marketing implies."
tags = ['ugreen', 'nas', 'ugos', 'btrfs', 'ext4', 'filesystem', 'data-recovery', 'lock-in', 'btrbk', 'samba', 'xattr']
draft = false
+++

If your UGREEN NAS dies — board failure, lightning, sudden silent flake — and you pull the disks out and connect them to a Linux machine to recover your data, the disks won't mount. UGOS's ext4 volumes have an undocumented feature flag (`FEATURE_I29`) that standard `e2fsprogs` rejects. UGOS's btrfs volumes are reportedly modified too. The on-disk format isn't quite the on-disk format you think it is.

This post is about three filesystem-layer modifications UGOS does, each of which I've either run into directly or seen reported by other users in the [r/UgreenNASync subreddit](https://www.reddit.com/r/UgreenNASync/). Individually they're surprising. Together they paint a coherent picture: UGOS has been engineered as if the disks are not meant to leave the NAS — and the marketing materials don't mention this.

**Up front**: I am a paying UGREEN customer. I bought three NASync DXP units at full retail to run as a three-site replication mesh, and I'm broadly happy with the hardware. I'm writing this as a customer who would like to understand the data-resilience properties of devices I trust with my files, not as a competitor or a critic looking to score points.

**TL;DR**:

- **UGOS-managed btrfs storage pools have a non-standard `incompat_flags` bit set in their superblock.** First-hand: my own pool's `btrfs inspect-internal dump-super` shows `incompat_flags 0x4000000000000361` — bit 62 is set, well outside the documented 0-15 range of upstream btrfs feature flags. Standard `btrfs-progs` will refuse to mount a filesystem with unknown incompat bits, by design.
- **UGOS-managed ext4 storage pools reportedly have a similar non-standard feature flag.** Other users in the r/UgreenNASync sub report `FEATURE_I29` rejection on Debian 13: `Filesystem has unsupported feature(s) while trying to open /dev/mapper/ug_75C8E3_..._pool2-volume1 Couldn't find valid filesystem superblock. volume1 has unsupported feature(s): FEATURE_I29`. **External USB drives formatted via UGOS UI as ext4 don't show this** — I confirmed on my own NAS that a USB ext4 drive has only standard features. The non-portability is specific to UGOS *storage pools*, which use UGOS's RAID/device-mapper layer.
- **UGOS writes a `system.ugacl_self` extended attribute** in the kernel-reserved `system.*` xattr namespace via a kernel module (`ugacl_vfs.ko`). Standard `btrfs send | btrfs receive` produces a stream that mainline-btrfs receivers reject with `ENOTSUP` on those xattrs. Cross-NAS replication via the obvious tool (`btrbk`) breaks until you filter the xattrs out at receive time. (UGOS also uses a custom `ug.*` xattr namespace for share-level metadata like `ug.archive_bit`, which I verified directly on share root inodes; that's a separate but related quirk.)
- **The bind-mount FS-shim** presents the same inode with mode `0777` on the host filesystem and mode `0000` inside containers. Trips up git (`core.fileMode` checks), trips up containers that mount data directories with bind mounts, surfaces in production-like environments as confusing permission failures.
- **UGOS's own "Sync & Backup" feature uses `rsync`**, not native `btrfs send/receive` — which suggests that even UGREEN's first-party software treats the native btrfs replication primitives as not survivable across their own modifications. The `backup_tool` binary contains 16 distinct rsync code-path references (including Go package paths like `ctl_serv/cmd/backup_tool/backuprestore/backup_filemgr_rsync.go`) and **zero `btrfs` substrings** — UGOS's first-party backup code doesn't even import a btrfs library.

The aggregate effect: in practice, UGOS-formatted disks are not portable to non-UGOS Linux systems, and even within the UGOS world, the standard filesystem tooling has rough edges that surface when you try to use the disks the way Linux usually lets you.

The modifications described in this post are GPL-licensed software that UGOS ships in modified form; the corresponding source code is not published. That's its own subject for another post — this one is about the operational effects on you as a NAS user, not the licensing question.

The four troubles below are surfaces of a single underlying feature UGREEN added to support their Windows-style ACL system. Holding that picture in mind first helps:

{{< mermaid >}}
flowchart TB
    feature["UGREEN's <code>ugacl</code> feature<br/>(Windows-style per-file ACLs<br/>layered on POSIX ACLs)"]

    feature --> ext4["ext4 superblock:<br/>'ugacl' incompat feature<br/>(seen as <code>FEATURE_I29</code><br/>by upstream e2fsprogs)"]
    feature --> btrfs["btrfs incompat_flags:<br/>bit 62 set<br/>(<code>0x4000000000000000</code>)"]
    feature --> kmod["Kernel modules:<br/><code>ugacl_vfs.ko</code><br/><code>ug_posix_acl.ko</code>"]
    feature --> samba["Samba VFS object:<br/><code>ug_xattr_filter</code><br/>+ patched libsmbd"]

    ext4 --> nomount["UGOS pool disks<br/>can't mount on<br/>standard Linux"]
    btrfs --> nomount
    kmod --> xattr["<code>system.ugacl_self</code> writes<br/>via kernel-namespace hook<br/>+ <code>ug.*</code> custom namespace"]
    xattr --> noreplicate["Cross-NAS <code>btrfs send/receive</code><br/>fails on receive side<br/>without ugacl-aware kernel"]
    samba --> uionly["UI populates user list<br/>only via <code>ldapsam</code> +<br/>UGOS-formatted pools"]

    classDef root fill:#cfe7ff,stroke:#2563aa
    classDef surface fill:#f0e3ff,stroke:#6f3eb8
    classDef effect fill:#fff2c2,stroke:#a86b00
    class feature root
    class ext4,btrfs,kmod,samba surface
    class nomount,xattr,noreplicate,uionly effect
{{< /mermaid >}}

The four troubles each unpack one branch of that picture.

## Trouble #1: `system.ugacl_self` xattrs and cross-NAS btrfs replication

I run a three-site replication mesh — three NASync DXPs in three physical locations, replicating btrfs snapshots between them with [`btrbk`](https://github.com/digint/btrbk). The receivers run inside Alpine containers on the destination NAS.

Some replication runs were aborting partway through with this error:

```text
ERROR: lsetxattr "system.ugacl_self" = ...: Not supported
```

`system.ugacl_self` is an extended attribute UGOS sets on UGOS-managed files. It is not a Linux kernel xattr. It is not POSIX. It is not part of any standard. UGREEN added it as part of their `ugacl` feature — the same one that surfaces as the ext4 superblock flag and the btrfs bit-62 incompat flag I document in the next two sections — to support their Windows-style per-file ACL system. The xattr lives in the `system.*` namespace, which is the namespace [reserved by the Linux kernel](https://man7.org/linux/man-pages/man7/xattr.7.html) for in-kernel use. UGREEN makes that namespace work by way of a kernel module — `ugacl_vfs.ko`, loaded at boot, which I verified is present:

```text
$ lsmod | grep -E "ugacl|ug_posix"
ug_posix_acl           12288  0
ugacl_vfs              40960  2
```

The module hooks the VFS xattr layer to accept `system.ugacl_self` writes that the upstream kernel would refuse with `ENOTSUP`. The hook is gated on the host's mount namespace — which is why containerized receivers fail. They run in a different mount namespace, so the kernel module isn't intercepting their writes, so the writes get to the upstream kernel's `ENOTSUP` path.

UGOS's modified `btrfs-progs` knows about `system.ugacl_self` and will write it correctly. Mainline `btrfs-progs` running inside an Alpine container on the same hardware will not. `btrfs send` from a UGOS source includes `system.ugacl_self` in the stream; `btrfs receive` in a non-ugacl-aware userspace tries to apply it and fails.

The path the failure takes:

{{< mermaid >}}
sequenceDiagram
    participant src as Source NAS (UGOS kernel + ugacl_vfs.ko)
    participant net as Network
    participant rcv as Receiver (Alpine container, mainline btrfs)

    note over src,rcv: btrbk replicating snapshots cross-NAS
    src->>src: btrfs send /volume1/snapshot
    note over src: ugacl_vfs reads<br/>system.ugacl_self<br/>from each file
    src->>net: stream includes system.ugacl_self xattrs
    net->>rcv: stream arrives
    rcv->>rcv: btrfs receive /target
    note over rcv: container in different<br/>mount namespace<br/>ugacl_vfs hook not intercepting
    rcv-->>src: ERROR lsetxattr<br/>system.ugacl_self<br/>Not supported
{{< /mermaid >}}

There's a related quirk worth noting: UGOS also uses a custom `ug.*` xattr namespace for share-level metadata (separate from the kernel-namespace `system.ugacl_self`). Running `getfattr -d -m '-'` on a UGOS share root returns entries like:

```text
ug.archive_bit=0sAAIAAA==
ug.archive_version=0sUiUBAAEAAAA=
user.allow_only_admin_recycle.status="true"
user.data_check.status="false"
user.network_places_hide.status="false"
user.no_permission_hide.status="true"
user.share_folder_key.type="1"
```

The `ug.*` prefix isn't one of the four namespaces standard Linux recognizes (`user.*`, `system.*`, `trusted.*`, `security.*`); it's a UGREEN-specific addition. Standard `getfattr` will display these with the `--no-namespace-prefix` flag missing, so they're easy to overlook.

The workaround for the replication problem is to filter the `system.ugacl_self` xattr at receive time. I patched `btrbk`'s receive path to strip those entries from the incoming stream — that's the cleanest place to break the chain, because once the xattr gets to `btrfs receive` it's already too late. The fix is in [my ugreen-nas-compose repo](https://github.com/geoffdavis/ugreen-nas-compose) on the relevant PRs.

The takeaway from this one: **UGOS's xattr namespace usage extends to the kernel-reserved namespace and isn't compatible with standard Linux btrfs tooling**. If you want cross-NAS replication using mainline tools, you have to detect and filter UGOS-specific metadata at boundary crossings.

## Trouble #2: UGOS-managed btrfs pools carry a non-standard `incompat_flags` bit

This one I reproduced on my own NAS, on the live storage pool I'm using right now. `sudo btrfs inspect-internal dump-super -f /dev/mapper/ug_<MAC>_<TIMESTAMP>_pool2-volume1` returns:

```text
magic                   _BHRfS_M [match]
fsid                    5964069f-5d23-4e07-a407-d4d544be70ec
label                   pool2
compat_flags            0x0
incompat_flags          0x4000000000000361
```

`incompat_flags = 0x4000000000000361` decomposes as `0x361 | 0x4000000000000000`. The `0x361` low bits are all standard btrfs features: `MIXED_BACKREF (0x1) | BIG_METADATA (0x20) | EXTENDED_IREF (0x40) | SKINNY_METADATA (0x100) | NO_HOLES (0x200)`. The high bit — `0x4000000000000000`, bit 62 — is **outside the upstream btrfs feature-flag space**. Upstream `btrfs-progs` and the upstream kernel allocate bits 0 through ~15 for features (`MIXED_BACKREF`, `DEFAULT_SUBVOL`, `MIXED_GROUPS`, `COMPRESS_LZO`, `COMPRESS_ZSTD`, `BIG_METADATA`, `EXTENDED_IREF`, `RAID56`, `SKINNY_METADATA`, `NO_HOLES`, `METADATA_UUID`, `RAID1C34`, `ZONED`, `EXTENT_TREE_V2`, `RAID_STRIPE_TREE`, `SIMPLE_QUOTA`). Bit 62 is unallocated by upstream; it's a UGREEN-specific feature flag.

Because this bit is in the `incompat_flags` field — which by btrfs's design contract MUST be fully understood by the mounting kernel, otherwise the mount is refused — a standard Linux distribution running upstream `btrfs-progs` will reject this disk. It will not say "I'll ignore that bit and mount anyway"; it will say "I don't recognize this feature, refusing to mount."

The kernel's evaluation of the `incompat_flags` value, set bit by set bit:

{{< mermaid >}}
flowchart TB
    sb["btrfs superblock<br/><code>incompat_flags = 0x4000000000000361</code>"]
    sb --> b0["bit 0 (0x1)<br/>MIXED_BACKREF"]
    sb --> b5["bit 5 (0x20)<br/>BIG_METADATA"]
    sb --> b6["bit 6 (0x40)<br/>EXTENDED_IREF"]
    sb --> b8["bit 8 (0x100)<br/>SKINNY_METADATA"]
    sb --> b9["bit 9 (0x200)<br/>NO_HOLES"]
    sb --> b62["bit 62 (0x4000000000000000)<br/>?"]

    b0 --> known1["known to upstream ✓"]
    b5 --> known2["known ✓"]
    b6 --> known3["known ✓"]
    b8 --> known4["known ✓"]
    b9 --> known5["known ✓"]
    b62 --> unknown["NOT in any upstream<br/>btrfs feature table<br/>(allocated bits: 0–15)"]

    unknown --> refuse["Upstream btrfs-progs:<br/>refuse to mount<br/>(incompat contract: unknown bits = no mount)"]

    classDef ok fill:#bef0c0,stroke:#2a7a3a
    classDef bad fill:#f5d4d4,stroke:#a83030
    class known1,known2,known3,known4,known5 ok
    class b62,unknown,refuse bad
{{< /mermaid >}}

That's first-hand evidence that UGOS pools format their btrfs in a way that's not portable to non-UGOS Linux. Other users in [the r/UgreenNASync thread](https://www.reddit.com/r/UgreenNASync/comments/1pzviqw/), notably user `Stefouch`:

> Here I tried with BTRFS and same issue, cannot be mounted on Linux. Another redditor told me in this sub that's because Ugreen uses a modified version of the BTRFS.

— back this up from the practical-mounting angle. If you pull a UGOS pool disk and connect it to a Linux box, you can't `mount` it. UGOS also ships a forked `btrfs-progs` (distinct binary from the upstream Debian package, ~600 KB larger, MD5-mismatched on `dpkg --verify`) which presumably understands bit 62, but you can only run that binary on a UGOS host.

## Trouble #3: ext4 `ugacl` feature on UGOS pools — same root cause, second surface

I created a fresh ext4 volume in UGOS's UI (Storage Manager → Add Volume on an existing pool, format as ext4), and ran `dumpe2fs -h` on the resulting `/dev/mapper/ug_<MAC>_<TS>_pool1-volume2` device. Its `Filesystem features` line:

```text
Filesystem features:      has_journal ext_attr resize_inode dir_index orphan_file
                          filetype needs_recovery extent 64bit flex_bg
                          metadata_csum_seed ugacl sparse_super large_file
                          huge_file dir_nlink extra_isize quota metadata_csum
                          project orphan_present
```

The `ugacl` flag in that list is the smoking gun. Upstream ext4 has no `ugacl` feature; UGREEN's patched `e2fsprogs` (the binary that ships with UGOS) is the only `dumpe2fs` that knows the name. A standard Debian or Ubuntu system running upstream `e2fsprogs` would see the same bit set in `s_feature_incompat`, fail to look it up in its known-features table, and report it as `FEATURE_I29` — which is exactly what user `Feisty-Hat7145` reported in the [r/UgreenNASync thread](https://www.reddit.com/r/UgreenNASync/comments/1pzviqw/) on whether to replace UGOS:

> I did not try with btrfs but with ext4. Ugos has a proprietary Version of ext4 in use.. it cannot be mounted on Debian 13.
>
> `Filesystem has unsupported feature(s) while trying to open /dev/mapper/ug_75C8E3_1761865210_pool2-volume1 Couldn't find valid filesystem superblock.`
>
> `volume1 has unsupported feature(s): FEATURE_I29`

`FEATURE_I29` is upstream `e2fsprogs`'s default name for "incompat bit 29, no name registered" — i.e., `ugacl` as seen by a Linux that doesn't have UGREEN's patched `e2fsprogs`. Same bit, two different views. That's first-hand reproduction (my Volume 3) plus the field report explaining why a standard Linux box won't mount it.

The `ugacl` ext4 feature plus the bit 62 in btrfs `incompat_flags` plus the `ugacl_vfs.ko` kernel module loaded at boot are all manifestations of *one* feature UGREEN added across the storage stack: their Windows-style ACL system, layered onto every UGOS-managed pool regardless of which filesystem you choose at format time. Three surfaces, one feature.

But there's a sharp line worth drawing. **External USB drives formatted by UGOS as ext4 do not have the `ugacl` feature.** I verified directly: I attached a USB drive, used UGOS UI to format it as ext4, and ran `dumpe2fs -h /dev/sdh1`. Its features list contains only standard upstream flags — no `ugacl`, no surprises. The USB drive is portable to any standard Linux distribution.

So UGOS's behaviour is split:

| Filesystem context | Standard Linux can mount? | `ugacl` flag set? |
| --- | --- | --- |
| UGOS pool btrfs (`/dev/mapper/ug_*_poolN-volumeN`) | **No** — `incompat_flags` bit 62 | implicit |
| UGOS pool ext4 (`/dev/mapper/ug_*_poolN-volumeN`) | **No** — `FEATURE_I29` reported by upstream tools | yes |
| UGOS-formatted USB ext4 (`/dev/sdh1`) | **Yes** — standard upstream features | no |
| ZFS pool (e.g., from TrueNAS) | Yes — open on-disk spec | n/a |

UGOS treats the two contexts differently: pool-resident filesystems get the `ugacl` feature by default; external/portable drives don't. From an engineering-defensibility standpoint that's actually reasonable — your portable thumb drive *stays* portable — but the data-pool case is what most users care about, and the data-pool case is UGOS-only.

The two paths in one picture:

{{< mermaid >}}
flowchart LR
    ui[UGOS UI<br/>Storage Manager] --> choice{"format target?"}
    choice -->|"RAID pool<br/>(internal disks)"| pool[/dev/mapper/<br/>ug_*_pool*-volume*/]
    choice -->|"External device<br/>(USB drive)"| usb[/dev/sd*1/]
    pool --> pbtrfs["btrfs<br/>incompat_flags<br/>bit 62 set"]
    pool --> pext4["ext4<br/>'ugacl' feature<br/>set"]
    usb --> uext4["ext4<br/>standard upstream<br/>features only"]
    pbtrfs --> nope["NOT portable<br/>standard Linux<br/>refuses to mount ✗"]
    pext4 --> nope
    uext4 --> yep["Portable ✓<br/>any Linux mounts"]

    classDef bad fill:#f5d4d4,stroke:#a83030
    classDef good fill:#bef0c0,stroke:#2a7a3a
    class nope bad
    class yep good
{{< /mermaid >}}

The ZFS-on-TrueNAS comparison comes from the same Reddit thread (`Feisty-Hat7145`'s observation): ZFS works elsewhere because the on-disk format is a public specification and any Linux with `zfs-utils` installed can import the pool. The same is *theoretically* true of stock ext4 and stock btrfs — they're public formats, any Linux can mount them. But UGOS doesn't ship stock ext4 or stock btrfs *for storage pools*; the pool layer adds the `ugacl` feature.

A separate reproducible-quirk worth noting: UGOS's UI "Volume 3" maps to device-mapper's `pool1-volume2`. UGOS UI numbers volumes globally across pools (Volume 1 in pool1, Volume 2 in pool2, Volume 3 again in pool1, etc.); device-mapper numbers volumes within a pool. They drift by however many cross-pool UI volumes you've created. If you're trying to identify which `/dev/mapper/...` device corresponds to a UI volume, check the mount table (`/proc/mounts`).

## Trouble #4: bind-mount FS-shim mode bits

This one I hit while running Docker Compose stacks on the NAS with bind-mounted data directories. Stat the same inode from the host shell and from inside a container, and you get different answers.

```text
$ stat -c "%a %n" /volume2/docker/some-stack/config
0777 /volume2/docker/some-stack/config

$ docker exec some-container stat -c "%a /data/config" /data/config
0000 /data/config
```

Same path, same inode, different mode bits. The only thing that changed is which mount namespace is asking.

Practical effects:

- **Git repositories cloned onto `/volume2`** (UGOS's standard data partition) appear to have every tracked file changed, because git's `core.fileMode` check sees the mode flipping between operations. Workaround: `git config core.fileMode false` in the affected repo.
- **Docker containers that bind-mount data** sometimes silently shadow files when the bind-mount source path is missing — `dockerd` auto-creates an empty directory at the source path, which masks the file you intended to mount.
- **Compose stacks using relative paths** (`./config:/data/config`) interact unpredictably with this: depending on what part of the path is being resolved by which layer, you may end up with a 0000-mode file inside the container that the application can't read or write.

The fix in most cases is "use absolute paths" plus `core.fileMode false` for git. Workable but, again, not how Linux usually behaves.

## What UGREEN themselves do

The most informative observation about whether UGOS's filesystem modifications are battle-tested isn't in my reverse-engineering — it's in UGREEN's own product behaviour.

UGOS's "Sync & Backup" application is the official first-party way to replicate data between two UGREEN NASes. The binary that powers it is `/ugreen/@appstore/com.ugreen.ctlmgr/sbin/backup_tool`. Strings in that binary contain 16 distinct rsync code-path references, with explicit Go package paths:

```text
ctl_serv/cmd/backup_tool/backuprestore/backup_filemgr_rsync.go
ctl_serv/service/filesrv/rsync
ctl_serv/service/filesrv/rsync.GetRsyncServer
ctl_serv/service/filesrv/rsync.GetRsyncServer.func1
*rsync.RsyncConfig
*rsync.rsyncServer
/etc/rsyncd.json.backup
com.ugreen.pro.system.filemgr.rsync
```

And **zero** strings containing `btrfs` anywhere in the binary. UGREEN's first-party backup code doesn't even import a btrfs library. It uses `rsync` exclusively for NAS-to-NAS replication, even though the source and destination filesystems are both UGOS-managed btrfs and the native `btrfs send | btrfs receive` exists specifically to make this kind of data movement efficient and atomic.

If UGREEN's own replication code couldn't trust their own filesystem modifications to round-trip cleanly through `btrfs send | btrfs receive`, that's a strong signal about what the modifications break. It's also entirely consistent with the `system.ugacl_self`-in-the-system-namespace observation: UGREEN evidently knows their xattr scheme is incompatible with standard btrfs tooling, and shipped a userspace workaround (rsync) rather than a kernel-side fix that would let the standard tooling work.

This is the most charitable read of the engineering choice. The less charitable read is that UGREEN didn't realize they had a portability problem until late, and worked around it with rsync rather than fixing the underlying schema. Either way, the user-facing effect is the same: their first-party backup product takes the same workaround path third-party tools have to take.

## What This Means for Data Resilience

If you're running a UGREEN NAS, your data is more UGOS-dependent than the marketing implies. Specifically:

- **Your NAS-to-other-NAS replication strategy needs to be rsync-flavored, not btrfs-flavored.** UGREEN's own Sync & Backup chose rsync for a reason. Third-party tools like `btrbk` do work, but you have to filter the UGOS-specific xattrs at the receive boundary. Rolling your own rsync workflow is the path of least resistance.
- **Your disaster-recovery plan can't assume "pull the disks, plug into a Linux box, recover the data."** Both ext4 and btrfs are reportedly modified in ways that break standard mounting. Plan accordingly: the recovery path looks like "buy another UGREEN NAS, plug the disks into it, hope the spare loads UGOS happily." That's a very different posture from a NAS where you can plug the disks into anything.
- **Your off-site backup strategy should write data in a portable format.** Whatever you back up to (cloud, another NAS, an external USB drive) should be readable by any Linux. `restic`, `borg`, `rclone`, plain `tar` to a stock-formatted disk — anything that doesn't depend on UGOS-flavoured filesystem tooling at restore time. *Don't* back up by `btrfs send`-ing a UGOS volume to a non-UGOS receiver and assuming you'll be able to mount it later; you probably won't.

This isn't a fatal problem. ZFS on TrueNAS, btrfs on a stock Linux NAS, ext4 on more or less anything — these are alternative postures that don't lock your data into a single vendor's stack. UGREEN's hardware is good and UGOS's UI is pleasant. But the filesystem modifications create a lock-in surface that I haven't seen UGREEN acknowledge in their marketing materials, and that homelab buyers should know about before they decide a UGREEN NAS is their long-term plan.

## What I'd Want UGREEN to Fix

In rough order of how much engineering effort each would take:

1. **Document the on-disk modifications.** A note in the user manual or product spec saying "UGOS-formatted ext4 includes proprietary feature flag `INCOMPAT_FEATURE_I29` and is not portable to standard Linux distributions; for portability, format your data volumes with [other option]." Customers can then make an informed decision. This is a documentation change, not a code change.
2. **Provide a "portable filesystem" option** in the volume creation wizard. Stock ext4, stock btrfs, or ZFS — any of these formatted without UGOS-specific feature bits would let users keep their data portable while opting out of whatever UGOS-specific functionality the proprietary bits enable.
3. **Move ugacl-style metadata out of the kernel-reserved `system.*` xattr namespace** and into `user.*`, where it belongs by Linux convention. `user.ugacl_self` would survive `btrfs send | btrfs receive` cleanly because mainline kernels accept arbitrary `user.*` xattrs without needing a kernel module.

Item #1 alone would close the worst of the gap. Customers who want UGOS as it ships, with the UI features it provides, can keep using it; customers who want filesystem portability can opt for the portable option at format time. Neither group is blocked.

## Reproducing This

All commands here are run as `nasadmin` (or whatever your admin user is) on a UGOS NASync. Adjust paths if your pool device names differ.

The kernel modules that implement `ugacl`:

```bash
lsmod | grep -E "ugacl|ug_posix"
# Expected: ug_posix_acl and ugacl_vfs loaded
```

The btrfs `incompat_flags` with bit 62 set on a pool volume:

```bash
sudo btrfs inspect-internal dump-super -f /dev/mapper/ug_*_pool*-volume* | head -10
# Look for: incompat_flags  0x4xxxxxxxxxxxxxxx — high nibble being non-zero
# means a bit above 60 is set, which is outside the upstream feature space
```

The ext4 `ugacl` feature on a pool volume (if you have one formatted ext4):

```bash
sudo dumpe2fs -h /dev/mapper/ug_*_pool*-volume* 2>/dev/null | grep "Filesystem features:"
# Look for: ugacl in the feature list
```

The same volume seen from outside UGOS would show `FEATURE_I29` as an unsupported feature in `e2fsprogs`'s "unsupported feature(s)" error.

The custom `ug.*` xattrs on share roots:

```bash
sudo getfattr -d -m '-' /volume1/SomeShare/ | head -10
# Expected: ug.archive_bit, ug.archive_version, plus user.* metadata
```

The bind-mount mode-bit divergence (run in two terminals):

```bash
# Host side
stat -c "%a %n" /volume2/docker/some-mounted-path

# Container side, inside any container that bind-mounts the same path
docker exec some-container stat -c "%a %n" /the/container/mount/point
```

The two `stat` calls return different mode-bit answers for the same inode.

The `backup_tool` binary's rsync orientation:

```bash
sudo strings /ugreen/@appstore/com.ugreen.ctlmgr/sbin/backup_tool | \
  grep -iE "^.*rsync|^.*restic|^.*btrfs"
# Expected: many rsync references with Go package paths,
# zero btrfs references
```

If your output diverges from the post — different model, different firmware, different filesystem layout — I'd be curious to know. Leave a comment or [open an issue](https://github.com/geoffdavis/ugreen-nas-compose/issues).

## Related

- [r/UgreenNASync — Have you replaced the operating system on your UGREEN?](https://www.reddit.com/r/UgreenNASync/comments/1pzviqw/have_you_replaced_the_operating_system_on_your/) — the source thread for the `FEATURE_I29` and modified-btrfs reports.
- [r/UgreenNASync — How can I mount a RAID1 drive directly?](https://www.reddit.com/r/UgreenNASync/comments/1pk7s0y/how_can_i_mount_a_raid1_drive_directly/) — earlier thread on the same disk-portability problem.
- [`btrbk` — incremental btrfs replication](https://github.com/digint/btrbk) — the upstream tool that surfaced the `system.ugacl_self` problem for me. Workable on UGOS with the receive-side filter.
- [Linux `xattr(7)` man page](https://man7.org/linux/man-pages/man7/xattr.7.html) — the convention that says `system.*` is kernel-reserved and `user.*` is what arbitrary userspace metadata is supposed to use.

The takeaway, for anyone arriving here from a search engine considering whether to buy a UGREEN NASync: the hardware is good, UGOS is mostly pleasant, but the filesystem layer has been modified in ways that affect your disaster recovery posture and your replication options. Plan for the modifications. Don't assume your disks will work outside a UGOS system.
