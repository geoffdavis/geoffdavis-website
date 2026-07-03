+++
date = '2026-07-03T12:00:00-07:00'
title = 'TrueNAS Replication to Stock OpenZFS: acltype=nfsv4, Foreign Snapshots, and the syncoid Handover'
description = "Firsthand test results for anyone planning a TrueNAS-to-NixOS (or any stock-OpenZFS) migration: TrueNAS's native replication (zettarepl) pushes cleanly into stock OpenZFS 2.4.2 with zero warnings, including datasets with acltype=nfsv4 — because NFSv4 ACLs travel as object-level metadata in the send stream, not as an enforced property. And syncoid can take over a zettarepl-created snapshot chain mid-flight, because it matches snapshots by GUID, not name. Plus the three gotchas that will bite you if you don't plan for them: sanoid never prunes foreign-named snapshots, syncoid silently falls back to a full re-send when the target is missing, and sanoid's recursive=yes is not atomic."
tags = ['truenas', 'zfs', 'openzfs', 'nixos', 'replication', 'zettarepl', 'syncoid', 'sanoid', 'nfsv4-acl', 'homelab', 'nas', 'migration']
draft = true
+++

If you're planning to migrate a TrueNAS box to NixOS — or to any distro running stock OpenZFS — the posts that exist (like [Bas Nijholt's excellent TrueNAS-to-NixOS writeup](https://www.nijho.lt/post/truenas-to-nixos/)) mostly cover the migration of the box itself: recreating shares, apps, and pool imports. What I couldn't find written down anywhere is what happens to **replication** during the awkward middle period — when part of your fleet is still TrueNAS and part of it isn't, and your snapshot chains have to survive not just a heterogeneous fleet but an eventual swap of the replication tooling itself.

So I tested it. This post is firsthand evidence, gathered 2026-07-02/03, with version numbers attached — because this is exactly the kind of behavior that changes between releases, and you should re-verify against your own versions rather than trusting a blog post forever.

**The test setup:**

- **Source**: TrueNAS CE 25.10.4, which ships iXsystems' ZFS fork (reports as `zfs-2.3.4`), pushing via TrueNAS's native replication tasks — the engine behind them is [zettarepl](https://github.com/truenas/zettarepl) — over SSH, with "Include Dataset Properties" enabled and snapshot retention policy set to `SOURCE`.
- **Target**: a NixOS 26.05 VM (kernel 6.18) running stock OpenZFS **2.4.2**. No iX patches, no TrueNAS middleware — just `boot.zfs` and an SSH account.

**TL;DR:**

- **TrueNAS → stock OpenZFS replication just works.** Initial full send, incrementals, recursive child datasets, and `SOURCE`-policy retention pruning of the *target* — zero warnings, zero errors. TrueNAS manages snapshots on a foreign OpenZFS system correctly.
- **`acltype=nfsv4` datasets replicate cleanly.** The property lands verbatim as a `received` property on the target. Stock Linux OpenZFS can't *enforce* NFSv4 ACLs (the xattr operations return `EOPNOTSUPP`), but the stream never fails.
- **The NFSv4 ACLs themselves survive** — they're object-level metadata in the send stream, not a dataset property. They travel losslessly even with properties excluded, and a round-trip send *back* to TrueNAS reproduces the ACEs bit-identically. A stock-OpenZFS replica is a faithful DR copy of ACL'd data even though it can't enforce the ACLs itself.
- **syncoid can take over a zettarepl-created replication chain** without a full re-send, because it matches snapshots by GUID rather than by name. It survives the complete handover — including the eventual destruction of every zettarepl-named snapshot on both sides.
- **Three gotchas**: sanoid never prunes foreign-named snapshots (your old zettarepl snaps sit forever unless you destroy them yourself); syncoid has no equivalent of TrueNAS's "full send from scratch" guard (a wiped target silently triggers a multi-week full re-send over a WAN); and sanoid's `recursive=yes` is non-atomic — you want `recursive=zfs`.

## Part 1: TrueNAS's Native Replication into Stock OpenZFS

### The boring good news

TrueNAS CE's replication tasks are driven by zettarepl, which speaks plain `zfs send | zfs receive` over an SSH transport. Point one at a stock OpenZFS 2.4.2 target and everything in the normal lifecycle works with zero warnings:

- **Initial full send** of a dataset tree.
- **Incremental sends** on the snapshot schedule.
- **Recursive replication** of child datasets.
- **Retention with `Snapshot Retention Policy: SOURCE`** — zettarepl doesn't just push snapshots, it *prunes the target* to match the source's retention. It did this correctly against a foreign system: expired snapshots got destroyed on the NixOS side on schedule, exactly as they would against another TrueNAS box.

That last one is worth pausing on, because it's the part that makes "TrueNAS pushing to not-TrueNAS" a legitimate long-term arrangement rather than a demo. The pusher is managing the full snapshot lifecycle on a target that has never heard of iXsystems, and nothing complains.

None of this should be surprising — the ZFS send stream format is a stable public interface, and zettarepl is doing standard things with it. But "should work" and "tested, works, these versions" are different claims, and when your data is the payload you want the second one.

### The scary property: `acltype=nfsv4`

Here's the question that actually motivated the test. TrueNAS datasets that back SMB shares typically have `acltype=nfsv4`. On TrueNAS, that's a real, enforced ACL system — but it's enabled by iXsystems' patches to both ZFS and the kernel. Mainline Linux ZFS has never supported NFSv4 ACL *enforcement*; the feature request is one of the oldest open issues in the project ([openzfs/zfs#4966](https://github.com/openzfs/zfs/issues/4966), open since 2016), with [PR #16967](https://github.com/openzfs/zfs/pull/16967) as the current implementation attempt, superseding the earlier [PR #13186](https://github.com/openzfs/zfs/pull/13186). As of OpenZFS 2.4.2, it remains unmerged.

So what happens when you replicate an `acltype=nfsv4` dataset, properties included, into a stock Linux OpenZFS that can't do NFSv4 ACLs?

Nothing bad. The stream never fails. The property lands verbatim on the target as a `received` property:

```text
$ zfs get acltype tank/replica/smb-data
NAME                   PROPERTY  VALUE     SOURCE
tank/replica/smb-data  acltype   nfsv4     received
```

One version note: stock OpenZFS 2.4.2 now *accepts* `acltype=nfsv4` on Linux at the property level — you can even `zfs create -o acltype=nfsv4` locally. What it can't do is enforce it: there's no VFS wiring, so NFSv4 ACL xattr operations against the mounted filesystem return `EOPNOTSUPP`. The replica mounts fine and the data is fully readable; the ACLs just don't gate anything on the replica itself.

### The important subtlety: ACEs are in the stream, not in the property

It would be easy to look at the above and conclude "the *property* replicates, but the actual ACLs are lost the moment they touch a system that can't enforce them." That's wrong, and it's the most useful single fact in this post:

**NFSv4 ACEs are object-level metadata inside the send stream, not a dataset property.** They're stored per-file in the ZFS object layer, they're serialized into the send stream alongside the file data, and `zfs receive` writes them to disk whether or not the receiving kernel can enforce them — and whether or not you included dataset properties in the send at all.

I verified this with a round trip: replicate an ACL'd dataset from TrueNAS to the stock-OpenZFS target, then send it *back* to TrueNAS and compare. The ACEs came back **bit-identical**. The stock Linux box in the middle couldn't enforce a single one of those ACLs, couldn't even display them with standard tooling — but it preserved every byte.

The practical consequence for a migration or DR plan:

| Question | Answer |
| --- | --- |
| Can I replicate ACL'd TrueNAS datasets to stock OpenZFS? | Yes, zero warnings |
| Does the replica enforce the NFSv4 ACLs? | No — xattr ops return `EOPNOTSUPP` |
| Are the ACLs *lost*? | No — they're on disk, byte-exact |
| If I restore back to a TrueNAS (or FreeBSD, or future NFSv4-capable Linux) system, do the ACLs work? | Yes — round-trip verified bit-identical |

A stock-OpenZFS replica is a **faithful DR copy of ACL'd data**. It's a cold archive of the ACLs, not an active enforcer of them. For a backup target — which is what a replication destination usually is — that's exactly what you need. And if mainline enforcement ever lands (the #16967 lineage), the ACLs are already sitting there waiting.

## Part 2: Handing the Pusher Role from zettarepl to syncoid

Part 1 covers the heterogeneous-fleet period: TrueNAS still runs the show, stock OpenZFS is just a target. But if the migration finishes — the TrueNAS source itself becomes NixOS — you need new replication tooling on the source side. The obvious candidate is [sanoid/syncoid](https://github.com/jimsalterjrs/sanoid). The question is whether syncoid can *take over* an existing zettarepl-created snapshot chain, or whether the tooling swap forces a full re-send of everything.

### syncoid doesn't care what your snapshots are named

zettarepl names its snapshots things like `auto-2026-07-02_14-00` (configurable, but always its own scheme). sanoid names its snapshots `autosnap_2026-07-02_14:00:02_hourly`. Naively you'd expect syncoid to look at a zettarepl-populated target and see nothing it recognizes.

It doesn't work that way. **syncoid matches snapshots by GUID, not by name.** Every ZFS snapshot carries a `guid` property that survives send/receive; syncoid lists snapshots on both sides, finds the newest one whose GUID exists on both, and sends the increment from there. The names are irrelevant.

In my test, syncoid pointed at a chain that zettarepl had built:

- It found the common snapshot immediately (a zettarepl-named `auto-*` snap).
- It sent an **incremental**, not a full: ~4.0 MB transferred against a 21 MB full-send estimate for the dataset.
- It delivered the intermediate snapshots along the way, keeping the chain intact on the target.

No flag day, no re-seed. The handover from zettarepl to syncoid is a non-event at the data layer.

### It survives the full transition, including snapshot turnover

The takeover test above still had zettarepl snapshots as the common ancestors. The stricter test is whether replication survives the *complete* transition:

1. sanoid starts running on the (now-NixOS) source and creates its own `autosnap_*` snapshots.
2. syncoid replicates on a schedule, anchoring on its own rotating sync snapshots.
3. Every zettarepl-named snapshot is destroyed — on **both** sides.

Result: incrementals continued unbroken. Once syncoid has run even once, its sync snapshots (plus the sanoid `autosnap_*` chain) provide the common GUIDs, and the zettarepl-era snapshots become dead weight rather than load-bearing history. After destroying all of them everywhere, the next incremental ran normally, and end-to-end checksums of the replicated data matched the source.

So the full migration story — TrueNAS/zettarepl fleet, then mixed fleet, then all-stock fleet on sanoid/syncoid — works without ever re-sending your data. That's the headline.

Now the three gotchas.

### Gotcha 1: sanoid will never clean up the zettarepl snapshots

sanoid prunes only snapshots matching its own `autosnap_*` naming convention. Foreign-named snapshots are invisible to its retention logic — by design, and it's the right design (a pruning tool that deleted snapshots it didn't create would be terrifying).

But it means the zettarepl-era `auto-*` snapshots **will never age out on their own** after the migration. They'll sit there holding referenced space forever. Plan a one-shot cleanup as an explicit migration step:

```bash
# Review first. Always review first.
zfs list -t snapshot -o name -s creation | grep '@auto-'

# Then destroy the zettarepl-named snaps on both source and target
zfs list -H -t snapshot -o name | grep '@auto-' | xargs -n1 zfs destroy
```

(Adjust the pattern to whatever your zettarepl naming schema was. And do this only *after* syncoid has established its own common snapshots — see the previous section.)

### Gotcha 2: syncoid has no `allow_from_scratch: false`

TrueNAS replication tasks have a safety property that's easy to take for granted: with "Replication from scratch" disabled (the default), zettarepl **refuses to run** if there's no common snapshot between source and target. A wiped or rolled-back target produces a loud error, not a silent decision.

syncoid's philosophy is the opposite: if the target dataset is missing or shares no common snapshot, it **silently starts a full send**. For a laptop-sized dataset on a LAN, that's self-healing and lovely. For a multi-TB dataset over a WAN, it's a multi-week background process you didn't ask for, saturating your uplink the whole time.

Some calibration numbers: a 14 TB dataset re-seeds in roughly **65 days at 20 Mbps**, or roughly **13 days at 100 Mbps**. If your replication target is off-site behind a residential uplink, an accidental from-scratch is not an incident you shrug off — it's a season.

My take: don't try to make syncoid refuse (self-healing is genuinely the behavior you want for DR — a re-seed that starts automatically at 3 AM after a disaster beats one that waits for you to notice a failed cron job). Instead, make it **observable and throttled**. Wrap syncoid in a script that:

1. Checks for a common snapshot before invoking syncoid (compare `zfs list -t snapshot -o guid` on both ends).
2. If there's no common snapshot, **notifies you** (mail, ntfy, whatever you alert with) that a full re-send is starting.
3. Applies `--target-bwlimit` with a time-of-day policy — unlimited overnight, something like 10–20 Mbps during prime hours so the household doesn't notice. syncoid implements rate limiting by riding `pv`/`mbuffer` in the pipeline, so the limit is cheap and reliable.

That converts the failure mode from "why has the internet been slow for three weeks" to "I got a notification that a re-seed started, and it's shaped to be invisible."

### Gotcha 3: recursion atomicity, and pruning the target

Two smaller ones, same theme — sanoid/syncoid's defaults don't match the semantics zettarepl gave you, and you have to opt back in.

**Atomic recursive snapshots.** zettarepl takes recursive snapshots atomically — one `zfs snapshot -r`, so every child dataset's snapshot represents the same instant. sanoid's `recursive = yes` walks the dataset tree and snapshots each dataset **individually** — children can be milliseconds-to-seconds apart, which matters if applications write across dataset boundaries. The fix is one word:

```ini
[tank/data]
    use_template = production
    recursive = zfs    # atomic zfs snapshot -r, matching zettarepl's behavior
```

**Pruning the target.** With retention `SOURCE`, zettarepl pruned the replication target for you. syncoid never prunes targets — it only ships snapshots. If nothing prunes the target, it accumulates every snapshot forever. The receiving side needs its own sanoid running a *prune-only* stanza:

```ini
[tank/replica/data]
    use_template = backup
    recursive = zfs
    autosnap = no      # never CREATE snapshots here (they'd break received-chain integrity)
    autoprune = yes    # only prune the ones syncoid delivers
```

The `autosnap = no` half is just as important as the `autoprune = yes` half: locally-created snapshots on a replication target are at best clutter and at worst rollback obstacles.

## What This Means If You're Planning the Migration

Putting it together, for the TrueNAS-to-NixOS (or -to-anything-stock) crowd:

- **You can migrate incrementally.** A stock-OpenZFS box is a fully functional replication target for a TrueNAS fleet today — including retention management, including ACL'd SMB datasets. You don't need to migrate every box at once, and the ugly middle period is genuinely fine.
- **Your ACLs are safer than they look.** `acltype=nfsv4` can't be enforced on stock Linux ZFS, but the ACEs ride the send stream losslessly and round-trip bit-identically. A stock replica is a faithful DR copy; enforcement comes back the moment the data lands on a system that supports it.
- **The tooling swap doesn't cost you a re-seed.** syncoid GUID-matches its way onto a zettarepl chain and keeps going incrementally, and the arrangement survives the complete death of every zettarepl-named snapshot.
- **Budget for the three gotchas**: a one-shot destroy of foreign snapshots (or they live forever), a wrapper that makes syncoid's silent from-scratch full sends observable and bandwidth-shaped (or a wiped target eats your WAN for weeks), and the `recursive = zfs` + prune-only-target sanoid config (or you lose atomicity and grow an immortal snapshot pile).

As always with ZFS behavior at version boundaries: these results are from TrueNAS CE 25.10.4 (zfs-2.3.4, iX fork) pushing to stock OpenZFS 2.4.2 on kernel 6.18, tested 2026-07-02/03. Re-verify against your versions — that's half the reason this post exists with version numbers in every claim.

## Related

- [Bas Nijholt — From TrueNAS to NixOS](https://www.nijho.lt/post/truenas-to-nixos/) — prior art on the box-migration side of this story.
- [openzfs/zfs#4966](https://github.com/openzfs/zfs/issues/4966) — the 2016-vintage feature request for NFSv4 ACLs on Linux; [PR #16967](https://github.com/openzfs/zfs/pull/16967) is the current implementation attempt (superseding [#13186](https://github.com/openzfs/zfs/pull/13186)).
- [truenas/zettarepl](https://github.com/truenas/zettarepl) — the replication engine behind TrueNAS's replication tasks.
- [jimsalterjrs/sanoid](https://github.com/jimsalterjrs/sanoid) — sanoid and syncoid.
