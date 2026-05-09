+++
date = '2026-05-07T22:00:00-07:00'
title = "What UGREEN UGOS's 'Active Directory' Domain Join Actually Does"
description = "UGOS's domain-join wizard offers an Active Directory option that successfully validates Kerberos against any AD-compatible domain controller, then fails at the 'final check' step. Reverse-engineering the binary that does the work reveals why: it never calls `net ads join`. The 'AD' option is structurally just an LDAP join with a Kerberos ping-test bolted on top, and that has implications for every modern directory you might want to put behind one of these NASes."
tags = ['ugreen', 'nas', 'samba', 'active-directory', 'ldap', 'kerberos', 'freeipa', 'lldap', 'reverse-engineering', 'ugos']
draft = false
+++

I have an LDAP directory at home. I want my NAS users to come from it, my WiFi to use it for 802.1X, and my cluster apps to authenticate against it through Authentik. One identity, three places.

The NAS part broke first.

UGREEN's UGOS (the OS that ships on their NASync line) has a "User Management" panel with a "Domain" option that promises both LDAP and Active Directory joins. I'd already done the LDAP join — UGOS happily bound to the LDAP server, the wizard reported success, and then the User Management UI showed *zero* LDAP users. None. The directory is operational, `getent passwd cami` resolves through SSSD, but the UI's user list is empty.

Investigating that took me into UGOS's `/etc/samba/smbldap.conf` and the discovery that UGOS uses Samba's `ldapsam` PASSDB backend to populate that UI. `ldapsam` filters by `(objectClass=sambaSamAccount)`. My LDAP server (Authentik's outpost) doesn't apply that objectClass to users. Empty filter result, empty UI.

The fix at this point looked obvious: switch from LDAP-mode to AD-mode. AD-mode would use Samba's `winbind` PASSDB instead of `ldapsam`. Winbind enumerates users via NETLOGON RPC, not LDAP filters, so the schema problem goes away.

The "obvious fix" didn't work. This post is about why.

**Up front**: I am a paying UGREEN customer. I bought three NASync DXP units at full retail to run as a three-site replication mesh, and I'm broadly happy with the hardware. I'm writing this as a customer who would like the directory wiring to work, not as a competitor or a critic looking to score points.

**TL;DR**:

- UGOS's "Active Directory" domain-join wizard does not perform an AD-domain-member join. It performs an LDAP join with a Kerberos `kinit` validation prepended to it.
- The binary that does the work is `/ugreen/@appstore/com.ugreen.ctlmgr/sbin/domain_tool`. `strings` on that binary contains exactly one `net ads` invocation: `net ads leave -v -U %s`. There is no `net ads join`. There is no `realm join`. There is no `adcli`.
- The wizard always writes `passdb backend = ldapsam:%s` to Samba's config and `id_provider = ldap` to SSSD's config, regardless of which UI option you select.
- The "Kerberos check passes, final check fails" failure mode you may have hit is not a misconfiguration. It is the wizard's LDAP-flavored commit step failing because your modern AD-compatible directory doesn't expose `sambaSamAccount` on user entries — exactly the same root cause that makes the LDAP-join path fail.
- Practical consequence: no modern directory product (FreeIPA, Authentik LDAP outpost, Samba 4 AD DC, Univention UCS) works as a UGOS backend out of the box. They would all fail at the same LDAP schema verification step. The only viable path I've found is [LLDAP](https://github.com/lldap/lldap), which exposes a GraphQL admin API that lets you add the `sambaSamAccount` objectClass to all users in one mutation.

This is documented after a Phase 0 PoC against FreeIPA + `ipa-adtrust-install` on UGOS firmware 1.15.0.0120. Everything below is what the PoC produced.

## What I Tried

A FreeIPA server, configured with `--setup-adtrust` to advertise itself as an Active Directory–compatible domain controller, running in a Docker container on one of the NASes themselves (macvlan-attached so it has its own L2 identity on the LAN), authoritative for a delegated DNS zone (`ipa.home.geoffdavis.com`) so the NAS can do AD SRV-record discovery. Realm `IPA.HOME.GEOFFDAVIS.COM`. NetBIOS name `IPA`. All the AD primitives in place:

```text
$ dig @172.29.50.48 +short SRV _ldap._tcp.dc._msdcs.ipa.home.geoffdavis.com
0 100 389 ipa-sdg.ipa.home.geoffdavis.com.

$ dig @172.29.50.48 +short SRV _kerberos._tcp.dc._msdcs.ipa.home.geoffdavis.com
0 100 88 ipa-sdg.ipa.home.geoffdavis.com.
```

The FreeIPA admin user has the well-known AD RID `-500`:

```text
ipaNTSecurityIdentifier: S-1-5-21-3167538697-4124218630-3335320558-500
```

The container's `smbd` accepts anonymous SMB enumeration:

```text
$ smbclient -L //172.29.50.48 -U "%"
        Sharename       Type      Comment
        ---------       ----      -------
        IPC$            IPC       IPC Service (Samba 4.22.4)
```

In other words: as far as any AD-aware client should be concerned, this is a perfectly serviceable AD DC.

## What UGOS's Wizard Did

I went into UGOS's UI, navigated to Control Panel → User Management → LDAP/Domain → **Active Directory**, filled in the realm, NetBIOS name, DC FQDN, and admin credentials, and submitted.

The wizard ran for about 30 seconds and reported "**domain is working normally**". This is the Kerberos pre-validation step: UGOS does a `kinit` against the DC, the DC issues a TGT, the wizard concludes the DC is reachable and responsive.

Then the wizard ran the next step — the "final check" — and reported a failure. No detailed error message. Just a generic "couldn't complete the join."

I checked the obvious things first. DNS resolves correctly. Ports 53/88/389/445/636 are reachable from the NAS host to the DC. The DC has a `cn=Computers` container ready to accept machine accounts. The admin credentials I supplied have permission to create them.

Then I checked the actual filesystem state on the NAS, expecting to find a partial AD-domain-member configuration that had failed somewhere mid-commit. What I found was different and more interesting.

```text
$ sudo grep -E "security|server role|workgroup|passdb backend" /etc/samba/smbglb.conf
workgroup     = CKGD
security      = user
server role   = standalone server
passdb backend = smbpasswd

$ sudo ls /etc/sssd
ls: cannot access '/etc/sssd': No such file or directory

$ sudo grep -E "^\s*default_realm|\[realms\]" /etc/krb5.conf
default_realm = DEDOMAIN
[realms]
        ATHENA.MIT.EDU = {
        ...
```

The Samba config is in **standalone-server mode** with the local-file (`smbpasswd`) PASSDB backend. There's no `security = ads`, no `server role = member server`, no `passdb backend = winbind`. The `workgroup` is set to `CKGD`, which is a value I'd configured manually on this NAS some time ago (the UGOS factory default on a fresh unit is `WORKGROUP`; I confirmed by checking my other two NASes). Either way, the workgroup is not `IPA` — which is what an AD-domain-member join against FreeIPA *should* have written, since `IPA` is the domain's NetBIOS name. The wizard preserved my pre-existing setting rather than committing the new AD-domain identity. SSSD wasn't configured at all — `/etc/sssd/` doesn't even exist as a directory on this system. `/etc/krb5.conf` is the upstream-default placeholder shipped by `krb5-config` four months ago, with `default_realm = DEDOMAIN` and a list of MIT/Athena realms. None of it had been touched.

The wizard validated Kerberos, marked the join as failed, and rolled back to a configuration that doesn't reflect the join attempt at all.

That doesn't look like a wizard that *tried* to do an AD-domain-member join and failed at the last step. It looks like a wizard that never tried in the first place.

The actual sequence of what happens during the join, mapped against where it succeeds vs where it fails:

{{< mermaid >}}
sequenceDiagram
    participant U as User<br/>(UGOS UI)
    participant W as Domain-Join<br/>Wizard
    participant DC as FreeIPA DC<br/>172.29.50.48
    participant DT as domain_tool<br/>(LDAPSAM path)
    participant FS as smb.conf<br/>+ sssd.conf

    U->>W: Submit (realm, NetBIOS, admin creds)
    W->>DC: kinit admin@IPA.HOME.GEOFFDAVIS.COM
    DC-->>W: TGT issued
    W-->>U: "Domain is working normally" ✓
    W->>DT: spawn (-event=start)
    note over DT: domain_tool always invokes the<br/>LDAPSAM code path, regardless of<br/>which UI option was selected
    DT->>DC: LDAP search<br/>(objectClass=sambaSamAccount)
    DC-->>DT: empty result<br/>(FreeIPA stores Samba data under<br/>ipantuserattrs, not sambaSamAccount)
    DT->>DT: schema verification fails
    DT->>FS: roll back to standalone defaults<br/>(security=user, passdb=smbpasswd)
    DT-->>W: failure
    W-->>U: "Final check failed" ✗
{{< /mermaid >}}

## What `domain_tool` Actually Does

The wizard shells out to a binary at `/ugreen/@appstore/com.ugreen.ctlmgr/sbin/domain_tool`. It's a Go binary, statically-ish linked, stripped, but Go binaries never strip cleanly — package names and string literals stay.

Here's what `strings` returns when grep'd for the parts that matter:

```text
$ sudo strings /ugreen/@appstore/com.ugreen.ctlmgr/sbin/domain_tool | grep -E "net (ads|rpc|getlocalsid)"
net ads leave -v -U %s
```

That's the *only* `net ads` invocation in the entire binary. There is no `net ads join`. There is no `net ads testjoin`. There is no `net rpc join`. The binary literally cannot perform the `net ads join` operation that turns a Linux system into an AD domain member, because that command isn't present in its code.

The Samba PASSDB configuration the binary writes:

```text
$ sudo strings /ugreen/@appstore/com.ugreen.ctlmgr/sbin/domain_tool | grep -E "passdb backend"
passdb backend = ldapsam:%s
```

One format string, one PASSDB option: `ldapsam`. No `winbind`. No `tdbsam`. No `ipasam` (FreeIPA's own PASSDB module that knows how to talk to FreeIPA's schema).

The SSSD configuration knobs the binary knows how to write:

```text
$ sudo strings /ugreen/@appstore/com.ugreen.ctlmgr/sbin/domain_tool | grep -E "id_provider|auth_provider|ldap_schema"
id_provider
auth_provider
ldap_schema
ldap_min_id
ldap_max_id
```

No string `id_provider = ad`. No string `id_provider = ipa`. The binary writes LDAP-flavored SSSD configs and only LDAP-flavored SSSD configs.

There's a Go function name preserved in the binary: `ctl_serv/cmd/domain_tool/domain.setSSSDConf`. That's the function that writes `sssd.conf`. Its only callable identity-provider mode is LDAP.

The systemd service that runs `domain_tool` is straightforward — a oneshot triggered on `-event=start`:

```ini
[Unit]
Description=Domain Tool
After=entry_serv.service
Requires=ugbus.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/domain_tool -event=start
ExecReload=/bin/kill -HUP $MAINPID

[Install]
WantedBy=multi-user.target
```

This is fired by the web UI's backend (`ctl_serv`) when the wizard's Submit button is pressed.

So the actual sequence of what happens when you click "AD Join" in UGOS's UI is:

1. The wizard does a `kinit` against the DC. If it succeeds, the wizard reports "domain is working normally."
2. The wizard hands off to `domain_tool`, which is the LDAP-join code path.
3. `domain_tool` tries to verify it can serve user enumeration through `ldapsam`, which queries `(objectClass=sambaSamAccount)` against the directory.
4. Modern AD-compatible directories do not apply `sambaSamAccount` to user entries:
    - **FreeIPA + `ipa-adtrust-install`** has the schema *defined* but stores Samba attributes under its own `ipantuserattrs` AUXILIARY class. Its file-server integration uses the FreeIPA-aware [`ipasam`](https://freeipa.readthedocs.io/en/ipa-4-11/designs/adtrust/samba-domain-member.html) PASSDB module instead.
    - **Authentik's LDAP outpost** doesn't apply it either. The Authentik project [closed the request as wontfix](https://github.com/goauthentik/authentik/issues/6834).
    - **Samba 4 AD DC** doesn't auto-apply it to AD users — Windows AD uses a different schema that gets mapped to Samba schema lazily on first SMB access.
5. The `ldapsam` query returns empty. `domain_tool` reports the "final check" failed. The wizard reports an unspecified error to the UI and rolls back.

The Kerberos validation in step 1 is real but confined to step 1. Nothing in steps 2–5 cares about Kerberos. The AD-mode path and the LDAP-mode path converge after step 1.

Visualised, what UGOS's domain-join wizard actually does — and what it deliberately doesn't:

{{< mermaid >}}
flowchart TB
    user[User clicks Domain-Join wizard]
    user --> ad["UI option: Active Directory"]
    user --> ldap["UI option: LDAP"]
    ad --> kinit["Pre-flight: kinit against DC<br/>(succeeds → 'domain working')"]
    ldap --> nop["No Kerberos pre-flight"]
    kinit --> dt
    nop --> dt
    dt["domain_tool -event=start"]
    dt --> writes["WRITES (always):<br/>passdb backend = ldapsam:%s<br/>id_provider = ldap<br/>cosmetic files (avahi, resolv.conf)"]
    dt -.-> never["NEVER calls / writes:<br/>net ads join<br/>realm join / adcli join<br/>winbind config<br/>id_provider = ad / id_provider = ipa<br/>passdb backend = winbind / ipasam<br/>krb5.conf realm config"]

    classDef written fill:#bef0c0,stroke:#2a7a3a
    classDef notwritten fill:#f5d4d4,stroke:#a83030
    class writes written
    class never notwritten
{{< /mermaid >}}

Both UI options funnel into the same LDAPSAM code path. The "AD" label is decoration on top of an LDAP-join implementation.

## What This Means If You're Trying to Use a Modern Directory

The set of LDAP backends that actually work with UGOS, in 2026, on hardware running domain_tool as it ships, is constrained by what `ldapsam` queries can resolve. Specifically: every user the UGOS UI is supposed to display has to have `sambaSamAccount` as one of its objectClasses, with the supporting attributes (`sambaSID` minimum, others as needed for SMB password verification).

That excludes basically everything modern. To save some other homelab person from rediscovering this: a working backend in 2026 needs to be one of —

- An OpenLDAP instance with a Samba `populate.ldif` schema applied at provision time, and per-user `sambaSamAccount` populated when each user is created. Doable, but the kind of yak-shave that has historically driven people *away* from running OpenLDAP. (See JumpCloud's [Configure Samba Support to Use Cloud LDAP](https://jumpcloud.com/support/configure-samba-support-to-use-cloud-ldap) for a ~2020 example of what this looks like.)
- A real Windows Active Directory domain controller. Untested in this PoC. Worth noting that if UGOS's wizard *did* successfully complete an AD-domain-member join — which I haven't been able to make it do — it might handle Windows AD via the Kerberos+LDAP combination that AD natively presents. But the empirical observation here is that the wizard never even tries to do `net ads join`, so I can't say for certain.
- **[LLDAP](https://github.com/lldap/lldap)** — a small purpose-built LDAP server with a GraphQL admin API. Its `addUserObjectClass` mutation applies a custom objectClass to all existing users in one call. Apply `sambaSamAccount` plus the Samba attributes you need, populate `sambaSID`, and UGOS's `ldapsam` query starts returning your users. This is the path I'm taking.

The thing this *doesn't* leave room for is the "let me deploy FreeIPA / Univention UCS / a Samba 4 AD DC and have UGOS Just Work" path that some people might assume from UGOS's UI labels. The UI labels do not mean what they say they mean.

## What I'd Want UGREEN to Fix

In rough order of how much engineering effort each would take:

1. **Document the actual behaviour.** A note in the UGOS user-manual section for the AD-join wizard, saying "the AD-join path uses LDAP under the hood and requires the directory to expose Samba schema on user entries." That's a documentation task, not a code change. Anybody trying to integrate a modern directory with their UGREEN NAS would save days of reverse-engineering.
2. **Wire up `passdb backend = ipasam:` for FreeIPA-targeted joins.** The `ipasam` module ships with Samba and is documented; supporting it in `domain_tool` is plausibly a few hundred lines of Go.
3. **Wire up the actual AD-domain-member path** (`net ads join`, winbind PASSDB, `id_provider = ad`, the `nsswitch.conf` writes) for the AD UI option. This is the meaty one — `domain_tool` would have to learn an entirely new code path. But it's also the one users are entitled to expect when the UI says "Active Directory."

I don't expect any of these to land soon, but documenting #1 alone would close 90% of the investigation gap and cost UGREEN essentially nothing.

## Reproducing This

If you want to verify any of the above on your own NAS, the relevant binary is at `/ugreen/@appstore/com.ugreen.ctlmgr/sbin/domain_tool`. The `strings` invocations from the post:

```bash
sudo strings /ugreen/@appstore/com.ugreen.ctlmgr/sbin/domain_tool | grep -E "net (ads|rpc)"
sudo strings /ugreen/@appstore/com.ugreen.ctlmgr/sbin/domain_tool | grep -E "passdb backend"
sudo strings /ugreen/@appstore/com.ugreen.ctlmgr/sbin/domain_tool | grep -E "id_provider|/etc/sssd"
```

The systemd service definition:

```bash
sudo cat /ugreen/@appstore/com.ugreen.ctlmgr/domain_tool/domain_tool.service
```

The post-failed-join state files:

```bash
sudo cat /etc/samba/smbglb.conf | grep -E "security|server role|passdb|workgroup"
sudo cat /etc/krb5.conf | head -10
sudo ls /etc/sssd 2>&1
```

If your binary differs (different firmware version, different model line), I'd be curious to know — leave a comment or [open an issue against the public repo](https://github.com/geoffdavis/ugreen-nas-compose/issues) where the PoC artifacts are preserved.

## Where the LLDAP Path Goes From Here

I have an [LLDAP PoC](https://github.com/geoffdavis/pi-talos-home-ops) on a separate branch where the schema-extension approach is verified working. The deployment design lives in that repo as well, with implementation queued. Future post if/when there are enough surprises in the implementation to warrant one.

The takeaway, for anyone arriving here from a search engine: if your NAS-side `(objectClass=sambaSamAccount)` query is returning zero results and your UGOS User Management UI is empty, the directory is the part you need to change, not the NAS. UGOS isn't going to grow a `winbind`-flavored or `ipasam`-flavored code path on the timeline you need. Pick a directory you can teach to serve `sambaSamAccount` — LLDAP is the lightest one I've found — and move on.

## Related

The Samba-schema-on-LDAP problem isn't UGREEN-specific. Other NAS firmware families have hit the same wall against Authentik's LDAP outpost — these threads are what convinced me the problem isn't going to be fixed upstream and the workaround has to live elsewhere:

- [authentik#19789 — *LDAP-Outpost as Samba Domain Controller*](https://github.com/goauthentik/authentik/issues/19789). Filed by a QNAP user with the same failure mode: QNAP firmware queries `sambaDomainName`, `sambaSID`, `sambaAlgorithmicRidBase`, `objectclass=sambaDomain`, and Authentik's outpost can't answer. Open, labelled `pr_wanted`.
- [authentik#6120 — *How to enable the "Samba Schema" on Authentik LDAP Provider?*](https://github.com/goauthentik/authentik/issues/6120). Synology DSM context: the DSM LDAP-join wizard exposes profile options labelled `Standard` (Synology native), `IBM Lotus Domino`, and `Open Directory`, and explicitly warns when the LDAP server doesn't support the Samba Schema. Synology's wizard at least *acknowledges* the gap; UGOS's silently fails. Closed `not_planned`.
- [authentik#8711 — *Add Samba schema*](https://github.com/goauthentik/authentik/issues/8711). Where Authentik maintainer @BeryJu states the position: *"This is not something we're planning to add, as this is outside the scope of the LDAP provider — the LDAP outpost is purely read-only."* Closed.

So the picture is: every major homelab NAS family (UGREEN, QNAP, Synology) hits this against Authentik's LDAP outpost, and the maintainer position is that it stays out of scope. The fix has to live in the directory-server layer.
