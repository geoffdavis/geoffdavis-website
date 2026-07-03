+++
date = '2026-07-03T11:30:00-07:00'
title = 'Kerberos-Only Samba as a FreeIPA Domain Member on NixOS'
description = "A recipe for running a NixOS file server as a FreeIPA domain member with all SMB authentication over Kerberos and NTLM disabled — including the failure modes you'll hit on the way: the pkgs.samba4Full talloc panic when winbindd loads idmap_sss, the NT_STATUS_BAD_TOKEN_TYPE you get from NixOS's default security = user, grafting sssd's idmap module onto samba's baked-in MODULESDIR with BindReadOnlyPaths, and the net setdomainsid / ipa-getkeytab -P / net changesecretpw dance that makes a domain member work with no NETLOGON and no ipa-adtrust-install. macOS mounts and Time Machine sparsebundles included."
tags = ['nixos', 'samba', 'freeipa', 'kerberos', 'sssd', 'winbind', 'macos', 'time-machine', 'linux', 'sysadmin']
draft = true
+++

I wanted a NixOS file server that behaves like a proper FreeIPA domain member: IPA users and groups own the files, every SMB session authenticates with Kerberos, NTLM is dead, macOS clients mount shares without password prompts, and Time Machine works. No Active Directory, no `ipa-adtrust-install`, no forked Samba packages.

That configuration exists and works. Getting there involved four or five failure modes that produce error messages with almost no search results, so this post is structured as a recipe with the failures inline — if you arrived here by pasting `NT_STATUS_BAD_TOKEN_TYPE` or `Bad talloc magic value` into a search engine, skip to the relevant section.

Everything below is from a live test: a NixOS 26.05 VM enrolled against a running FreeIPA realm, with macOS clients doing the mounting. All names in the snippets are sanitized (`IPA.EXAMPLE.COM` realm, `ipa1.ipa.example.com` IPA server, `fileserver.ipa.example.com` member) — the configs are reconstructed to be runnable-shaped, but substitute your own values throughout.

**TL;DR**:

- NixOS's [`security.ipa`](https://search.nixos.org/options?query=security.ipa) module plus a manual `ipa host-add` + `ipa-getkeytab` replaces `ipa-client-install` entirely. No enrollment script, no SASL-bind flakiness.
- **Do not use `pkgs.samba4Full`.** The AD-DC-capable build bundles a private copy of talloc; loading sssd's `idmap_sss` module (linked against system talloc) into its winbindd aborts with `Bad talloc magic value - wrong talloc version used/mixed`. Plain `pkgs.samba` works.
- NixOS's `services.samba` silently defaults `security = user`. A kerberized session setup against that standalone-server config fails with **`NT_STATUS_BAD_TOKEN_TYPE`**. You need `security = domain`.
- Samba's `MODULESDIR` is baked in at build time. Graft `idmap_sss` in with a merged modules directory bind-mounted over the baked path via `BindReadOnlyPaths` — and the module must be a real file **copy**, not a symlink, or the module loader dies on `ELOOP` ("Too many levels of symbolic links").
- The no-DC domain-member join is three commands: `net setdomainsid`, `ipa-getkeytab -P` for the `cifs/` principal, `net changesecretpw -f`. After that, SID↔UID mapping via `idmap_sss` works with **no NETLOGON, no `ipa-adtrust-install`, and no forked Samba**.
- `ntlm auth = disabled` kills password auth cleanly (`NT_STATUS_NTLM_BLOCKED`).
- macOS mounts with zero prompts over SMB 3.1.1 — but only if the name you mount **exactly matches the `cifs/` SPN**. FQDN always; never the IP, the short name, or `.local`.
- Time Machine–style sparsebundles on a `fruit` share work: `hdiutil create -type SPARSEBUNDLE` directly on the mount ran at ~110 MB/s in my test and reattached read-write cleanly.

## Why this shape

Two constraints drove the design.

First, **Kerberos-only**. NTLM against a FreeIPA backend is somewhere between "awkward" and "off" depending on how your realm is configured, and I didn't want it anyway — every client in scope (macOS, Linux) speaks Kerberos natively. Disabling NTLM entirely means there is no password-equivalent material sitting in Samba's database, and no downgrade path for a client to fall into.

Second, **no domain controller**. The classic way to get Samba talking to FreeIPA identities is `ipa-adtrust-install`, which turns your IPA server into something AD-shaped and historically dragged in a specially-patched Samba on the file-server side. I wanted the file server to be a plain domain *member* using stock packages, with SSSD as the single source of identity truth. This is roughly the architecture FreeIPA's own [`ipa-client-samba`](https://freeipa.readthedocs.io/en/latest/designs/adtrust/samba-domain-member.html) tool sets up on Fedora/RHEL — but that tool doesn't exist on NixOS, so we get to see all the moving parts it hides.

The pieces:

- **SSSD** (via `security.ipa`) resolves IPA users/groups for NSS and maps SIDs. Modern FreeIPA (4.9.8+) assigns SIDs to users and groups at install time even without `ipa-adtrust-install`, so the mapping data already exists in your realm.
- **winbindd** runs alongside smbd, but only as a SID↔ID translation broker — it delegates the actual mapping to SSSD through the `idmap_sss` module.
- **smbd** validates Kerberos tickets against a dedicated keytab holding the `cifs/fileserver.ipa.example.com` key.

## Step 1: Enroll the host without ipa-client-install

NixOS has no `ipa-client-install`, and that turns out to be a feature. The `security.ipa` module generates `krb5.conf`, `sssd.conf` (with the `ipa` provider), and installs the realm CA certificate — declaratively, from four values you already know:

```nix
security.ipa = {
  enable = true;
  realm = "IPA.EXAMPLE.COM";
  domain = "ipa.example.com";
  server = "ipa1.ipa.example.com";
  basedn = "dc=ipa,dc=example,dc=com";
  certificate = pkgs.fetchurl {
    url = "https://ipa1.ipa.example.com/ipa/config/ca.crt";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
};
```

What it does *not* do is create the host entry in IPA or fetch the host keytab. Do that by hand — one command on any admin workstation, one on the file server:

```bash
# anywhere with IPA admin credentials
kinit admin
ipa host-add fileserver.ipa.example.com --ip-address=192.0.2.20

# on the file server (ipa-getkeytab is in pkgs.freeipa)
kinit admin
ipa-getkeytab -s ipa1.ipa.example.com \
  -p host/fileserver.ipa.example.com -k /etc/krb5.keytab
```

Then verify both halves of the enrollment:

```bash
kdestroy
kinit -k          # authenticates as the host principal from the keytab
id alice          # resolves an IPA user through SSSD
```

If `kinit -k` gets a TGT and `id` returns your IPA user with full group membership, the host is enrolled. That's the whole thing. `ipa-client-install` — a script with a long history of SASL-bind flakiness on fresh enrollments — never runs. Everything it would have written is either generated by the NixOS module or fetched by `ipa-getkeytab`.

## Step 2: Do not use samba4Full (the talloc panic)

Here is the headline finding, and the error that has essentially zero search results as of this writing.

My first attempt used `pkgs.samba4Full`, on the theory that a domain member wants the most featureful build. With `idmap_sss` loaded (see Step 4), winbindd crashed on startup, every time, with a log like this (trimmed):

```text
Initialising custom vfs hooks from [irpc]
PANIC (pid 1234): Bad talloc magic value - wrong talloc version used/mixed
    in 4.23.1
INTERNAL ERROR: Signal 6: Aborted in winbindd (winbindd) pid 1234 (4.23.1)
If you are running a recent Samba version, and if you think this problem is
not yet fixed in the latest versions, please consider reporting this bug...
```

`Bad talloc magic value - wrong talloc version used/mixed` is [talloc](https://talloc.samba.org/talloc/doc/html/index.html)'s ABI tripwire: every talloc allocation carries a magic number derived from the library version, and if a chunk allocated by one talloc build is touched by a different talloc build in the same process, it aborts rather than corrupt memory.

Why are there two tallocs in one process? Because of a build flag. In nixpkgs, [samba's derivation](https://github.com/NixOS/nixpkgs/blob/master/pkgs/servers/samba/4.x.nix) only passes `--bundled-libraries=!talloc,...` (i.e. *link the system talloc*) when the LDAP/AD features are **off**:

```nix
++ optionals (!enableLDAP && stdenv.hostPlatform.isLinux) [
  # Quoted verbatim from nixpkgs; the missing comma between
  # !pyldb-util and !talloc is upstream's own — samba's waf tolerates it.
  "--bundled-libraries=!ldb,!pyldb-util!talloc,!pytalloc-util,!tevent,!tdb,!pytdb"
]
```

`samba4Full` enables the AD DC, which requires `enableLDAP = true`, which means samba builds and statically embeds its own *private* talloc (the AD DC needs exact-version ldb/talloc, so upstream requires bundling). Meanwhile sssd's `idmap_sss.so` is linked against the *system* `libtalloc.so`. Load that module into samba4Full's winbindd and you have two tallocs in one address space. The first cross-library allocation trips the magic check. Abort.

The fix is to not want the AD DC build. A domain member doesn't need it:

```nix
services.samba.package = pkgs.samba;   # NOT pkgs.samba4Full
```

Plain `pkgs.samba` is built `--without-ads --without-ldap` — which sounds alarming for a Kerberos setup but isn't. Those flags remove the *AD client* machinery (`net ads join`, AD LDAP lookups), not GSSAPI. Accepting Kerberos in the SMB session setup goes through system MIT krb5, which is fully present, and `security = domain` doesn't use the ADS code path at all. And because `enableLDAP = false` is the default, plain samba links the system talloc — the same one `idmap_sss.so` uses. One talloc, no panic.

## Step 3: security = domain (the NT_STATUS_BAD_TOKEN_TYPE)

With the right samba package in place, the next failure is quieter. Everything starts, `smbd` listens, and then a kerberized client gets:

```text
$ smbclient --use-kerberos=required //fileserver.ipa.example.com/media -c ls
session setup failed: NT_STATUS_BAD_TOKEN_TYPE
```

`NT_STATUS_BAD_TOKEN_TYPE` from a session setup means the server received a SPNEGO token it isn't configured to process — in this case, a Kerberos AP-REQ arriving at a server that doesn't think it's in a domain.

The cause is a NixOS default. `services.samba` ships this unless you override it:

```text
security = user
```

`security = user` makes smbd a **standalone server** (`ROLE_STANDALONE`): local passdb, NTLM-shaped authentication, no realm awareness. NixOS never surfaces this — there's no assertion, no warning, and the generated `smb.conf` looks plausible — so the first sign is that error string on the client.

A domain member needs:

```nix
services.samba.settings.global = {
  security = "domain";
  # ...
};
```

which puts samba into `ROLE_DOMAIN_MEMBER`. (You'll see `server role = member server` in Fedora's `ipa-client-samba` output — it's the same switch by another name.) After this, verify what samba thinks it is:

```bash
$ testparm -s 2>/dev/null | grep -E 'security|role'
        security = DOMAIN
```

The kerberized session setup still won't *succeed* yet — the server has no `cifs/` key and no domain SID — but it will now fail for honest reasons instead of `BAD_TOKEN_TYPE`.

## Step 4: Graft idmap_sss without rebuilding samba

Winbindd needs the [`idmap_sss`](https://man.archlinux.org/man/idmap_sss.8) module so that SID↔UID/GID mapping is answered by SSSD — the single source of truth that already knows your IPA ID ranges. The module ships with sssd, **not** with samba. On Fedora it's the `sssd-winbind-idmap` package dropping `sss.so` into samba's module directory.

On NixOS that directory doesn't exist as a mutable location. Samba's `MODULESDIR` is baked into the binaries at build time and points into samba's own store path:

```bash
$ smbd -b | grep MODULESDIR
   MODULESDIR: /nix/store/...-samba-4.23.1/lib/samba
```

You can't write into a store path, and rebuilding samba to add the module throws away the binary cache. The trick is to build a merged copy of the modules directory and bind-mount it over the baked path, for the samba services only:

```nix
let
  # samba dlopen()s idmap modules from a path baked in at build time
  # (MODULESDIR). Overlay a merged copy that includes sssd's idmap_sss.
  sambaModulesWithSss = pkgs.runCommand "samba-modules-with-idmap-sss" { } ''
    cp -rL ${pkgs.samba}/lib/samba $out
    chmod -R u+w $out
    # Must be a real copy. A symlink here fails at runtime: samba's module
    # loader resolves it THROUGH the bind mount, which points back at the
    # mount, and dlopen fails with ELOOP.
    cp ${pkgs.sssd}/lib/samba/idmap/sss.so $out/idmap/sss.so
  '';
in
{
  systemd.services.samba-smbd.serviceConfig.BindReadOnlyPaths = [
    "${sambaModulesWithSss}:${pkgs.samba}/lib/samba"
  ];
  systemd.services.samba-winbindd.serviceConfig.BindReadOnlyPaths = [
    "${sambaModulesWithSss}:${pkgs.samba}/lib/samba"
  ];
}
```

Two details earned their comments the hard way:

1. **`cp -rL`, and a real copy of `sss.so`.** My first version symlinked the module into a symlink-farm of the original directory. Winbindd then failed to load *any* module with `Too many levels of symbolic links` — the loader resolves the symlink to the canonical samba store path, which is now shadowed by the bind mount, which contains the symlink, which resolves to the store path... `ELOOP`. Copy the files.
2. **`BindReadOnlyPaths` scopes the overlay to the units.** The rest of the system still sees the pristine samba store path; only `samba-smbd` and `samba-winbindd` (note the NixOS unit names — not `smbd`/`winbindd`) see the merged directory sitting on top of `MODULESDIR`.

With the module in place, the idmap configuration in `smb.conf` can reference it:

```nix
services.samba.settings.global = {
  # ...
  "idmap config * : backend" = "tdb";
  "idmap config * : range" = "0 - 0";
  "idmap config IPA : backend" = "sss";
  "idmap config IPA : range" = "200000 - 2147483647";
};
```

The `IPA` domain range must cover your realm's actual ID range — check with `ipa idrange-find`. The deliberately-empty `*` range matches what `ipa-client-samba` writes on Fedora: nothing outside the IPA domain gets an allocated ID.

## Step 5: The no-DC domain-member dance

Here's the part that took the most reconstruction. A classic domain member gets its identity from a join: `net rpc join` or `net ads join` talks to a domain controller, creates a machine account, negotiates a machine password, and stores the domain SID and that password in `secrets.tdb`. We have no domain controller — FreeIPA without `ipa-adtrust-install` serves no NETLOGON — so nothing can do that negotiation for us.

But nothing in the *steady state* of a domain member actually requires NETLOGON if you never use NTLM pass-through and your idmap backend is `sss`. The join is just three facts landing in the right places, and you can place all three by hand. (This is, as far as I can tell, what TrueNAS's middleware does internally when it binds Samba to an IPA domain — reconstructed here from the outside.)

**Fact 1: the domain SID.** FreeIPA has had one since install (4.9.8+ runs the sidgen task by default). Fish it out of LDAP — it lives on the `ipaNTDomainAttrs` object:

```bash
$ ldapsearch -Y GSSAPI -b "cn=ad,cn=etc,dc=ipa,dc=example,dc=com" \
    "(objectclass=ipaNTDomainAttrs)" ipaNTSecurityIdentifier
ipaNTSecurityIdentifier: S-1-5-21-1234567890-234567891-345678912
```

Tell samba about it on the file server:

```bash
net setdomainsid S-1-5-21-1234567890-234567891-345678912
```

Without this, winbindd logs the (very searchable) `Could not fetch our SID - did we join?` and refuses to do anything useful.

**Fact 2: the `cifs/` service key.** Create the service principal, then fetch its keytab **with `-P`**, which sets the key from a password you choose instead of a random one:

```bash
# on an admin workstation
ipa service-add cifs/fileserver.ipa.example.com

# on the file server
ipa-getkeytab -s ipa1.ipa.example.com \
  -p cifs/fileserver.ipa.example.com \
  -k /var/lib/samba/samba.keytab -P
# prompts twice for a new key password — pick something long and KEEP IT
# for the next command; this rotates the key, invalidating any prior keytab
```

The `-P` is the whole trick. Normally you'd never want a password-derived service key, but samba's machine-account plumbing wants to know the machine *password*, not just the key — and `-P` is how you end up holding a password that provably matches the key in the KDC.

**Fact 3: the machine password in secrets.tdb.** Feed samba that same password:

```bash
# -i reads the password from stdin. Feed it from a 0600 file rather than
# an `echo` pipe — a pipe still exposes the secret to shell history and
# `ps`, and this whole recipe ultimately runs in a systemd activation
# script where no human is present to type it.
net changesecretpw -f -i < /run/secrets/cifs-machine-pw
```

`net changesecretpw` exists for exactly this scenario — the manpage warns you off it unless the machine password is *"already stored"* in the directory, which is precisely what `ipa-getkeytab -P` just did. The `-f` is mandatory; `-i` reads the password from stdin (omit it, at an interactive shell, to be prompted instead — but never pass it on the command line).

Point samba at the keytab and stop it from ever trying to rotate a password against the DC that isn't there:

```nix
services.samba.settings.global = {
  # ...
  "kerberos method" = "dedicated keytab";
  "dedicated keytab file" = "FILE:/var/lib/samba/samba.keytab";
  "machine password timeout" = "0";
};
```

Restart `samba-smbd` and `samba-winbindd`, then verify the mapping chain end-to-end:

```bash
$ wbinfo --name-to-sid alice
S-1-5-21-1234567890-234567891-345678912-1004 SID_USER (1)
$ wbinfo --sid-to-uid S-1-5-21-1234567890-234567891-345678912-1004
289600004
$ id alice   # same UID, via sssd — the two agree
```

One debugging tip that cost me an hour: **winbindd caches negative idmap results.** If you fix a broken `idmap config` and `wbinfo --sid-to-uid` *still* fails, you may be staring at a stale cache entry masking your now-correct config. `net cache flush` before concluding anything.

Also for the record: `wbinfo -t` (the trust-secret check) will *never* pass in this setup, because it works by making a NETLOGON call. That's expected and harmless — nothing in the Kerberos auth path or the sss idmap path uses it.

## Step 6: Kerberos-only — kill NTLM

```nix
services.samba.settings.global = {
  # ...
  "ntlm auth" = "disabled";
};
```

Note that the default for [`ntlm auth`](https://www.samba.org/samba/docs/current/man-html/smb.conf.5.html) is `ntlmv2-only`, which sounds strict but still permits NTLMv2 password auth. `disabled` refuses the NTLMSSP mechanism entirely. Verify it's actually dead:

```bash
$ smbclient -U 'alice%correct-password' --use-kerberos=off \
    //fileserver.ipa.example.com/media -c ls
session setup failed: NT_STATUS_NTLM_BLOCKED
```

Even the *correct* password is refused — there is no code path left that accepts one. In this architecture that's doubly true: NTLM verification on a domain member is pass-through authentication over NETLOGON, and we don't have a NETLOGON. Disabling NTLM converts what would be a confusing timeout-ish failure into a clean, immediate, honest refusal.

```bash
$ kinit alice
$ smbclient --use-kerberos=required //fileserver.ipa.example.com/media -c ls
  .                                   D        0  Fri Jul  3 20:14:11 2026
  ...
```

Ticket in, session up. That's the whole auth story now.

## Step 7: macOS mounts — the name must match the SPN

macOS speaks Kerberos SMB natively and needs zero configuration — but it is absolutely unforgiving about one thing: **the server name you mount must exactly match the `cifs/` service principal.**

```bash
# on the Mac
$ kinit alice@IPA.EXAMPLE.COM
$ mkdir -p ~/mnt/media
$ mount_smbfs //alice@fileserver.ipa.example.com/media ~/mnt/media
$ smbutil statshares -a | grep -E 'SMB_VERSION|SIGNING'
SMB_VERSION                   SMB_3.1.1
SIGNING_ON                    TRUE
```

No password prompt, no keychain dialog, SMB 3.1.1. The Finder path works identically (⌘K, `smb://alice@fileserver.ipa.example.com/media`).

What does *not* work — and fails in the most misleading way possible, with a password prompt that then can't succeed because NTLM is disabled:

- `//alice@192.0.2.20/media` — an IP address. There is no `cifs/192.0.2.20` principal, so macOS can't request a service ticket and falls back to password auth, which is blocked.
- `//alice@fileserver/media` — a short name. Same problem: the client requests a ticket for `cifs/fileserver`, the KDC has never heard of it.
- `//alice@fileserver.local/media` — mDNS. Same again.

If macOS prompts you for a password on a share you *know* is Kerberos-enabled, the first thing to check is the name in the mount URL, not the server. `klist` on the Mac will show you which service ticket it actually obtained (or didn't).

## Step 8: Time Machine–style shares over vfs_fruit

The share definitions, with the [fruit](https://www.samba.org/samba/docs/current/man-html/vfs_fruit.8.html) bits macOS wants:

```nix
services.samba.settings = {
  global = {
    # ... everything from the previous sections ...
    "vfs objects" = "fruit streams_xattr";
    "fruit:metadata" = "stream";
  };
  media = {
    path = "/srv/media";
    "read only" = "no";
    "valid users" = "@media";
  };
  timemachine = {
    path = "/srv/timemachine";
    "read only" = "no";
    "valid users" = "@backup-users";
    "fruit:time machine" = "yes";
  };
};
```

Rather than waiting a day for a real Time Machine cycle, I tested the thing Time Machine actually does: create a sparsebundle directly on the mounted share, fill it, detach, reattach:

```bash
$ hdiutil create -size 500g -type SPARSEBUNDLE -fs APFS \
    -volname "TM Test" /Volumes/timemachine/tmtest.sparsebundle
created: /Volumes/timemachine/tmtest.sparsebundle
$ hdiutil attach /Volumes/timemachine/tmtest.sparsebundle
/dev/disk4  ...  /Volumes/TM Test
```

Sustained writes into the attached sparsebundle ran at roughly **110 MB/s** in my test setup, and detach/reattach came back read-write with no dirty-bundle complaints. `fruit:time machine = yes` also makes the share advertise itself with the `TimeMachine` capability bit, so it shows up in Time Machine's destination picker on its own.

## Step 9: IPA groups as POSIX ACLs, through SMB

The final check: does group-based authorization actually flow from IPA through SSSD through the SMB session token to the filesystem? Set up a directory only one IPA group can enter:

```bash
# on the file server; 'editors' is an IPA group
mkdir /srv/media/editors-only
chgrp editors /srv/media/editors-only
chmod 0770 /srv/media/editors-only
```

Through a kerberized SMB session, a member of `editors` can traverse and write; a non-member gets `NT_STATUS_ACCESS_DENIED`. The important detail is *why* it works: the session token smbd builds for the connection carries the user's **full supplementary IPA group membership** — winbindd asks `idmap_sss`, `idmap_sss` asks SSSD, SSSD knows everything IPA knows. Finer-grained cases work the same way with POSIX ACLs:

```bash
setfacl -m g:editors:rwx /srv/media/projects
```

Group ACEs referencing IPA groups admit and deny correctly through smbd. Nothing SMB-specific ever has to be told about your groups — the filesystem is the policy, and IPA is the directory behind it.

## The assembled config

For reference, the complete illustrative `services.samba` block, all sections merged:

```nix
{ config, pkgs, ... }:
let
  sambaModulesWithSss = pkgs.runCommand "samba-modules-with-idmap-sss" { } ''
    cp -rL ${pkgs.samba}/lib/samba $out
    chmod -R u+w $out
    cp ${pkgs.sssd}/lib/samba/idmap/sss.so $out/idmap/sss.so
  '';
in
{
  security.ipa = {
    enable = true;
    realm = "IPA.EXAMPLE.COM";
    domain = "ipa.example.com";
    server = "ipa1.ipa.example.com";
    basedn = "dc=ipa,dc=example,dc=com";
    certificate = pkgs.fetchurl {
      url = "https://ipa1.ipa.example.com/ipa/config/ca.crt";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  };

  services.samba = {
    enable = true;
    package = pkgs.samba;              # NOT samba4Full (private talloc)
    winbindd.enable = true;
    settings = {
      global = {
        workgroup = "IPA";
        realm = "IPA.EXAMPLE.COM";
        security = "domain";           # NOT the "user" default
        "machine password timeout" = "0";
        "kerberos method" = "dedicated keytab";
        "dedicated keytab file" = "FILE:/var/lib/samba/samba.keytab";
        "ntlm auth" = "disabled";
        "idmap config * : backend" = "tdb";
        "idmap config * : range" = "0 - 0";
        "idmap config IPA : backend" = "sss";
        "idmap config IPA : range" = "200000 - 2147483647";
        "vfs objects" = "fruit streams_xattr";
        "fruit:metadata" = "stream";
      };
      media = {
        path = "/srv/media";
        "read only" = "no";
        "valid users" = "@media";
      };
      timemachine = {
        path = "/srv/timemachine";
        "read only" = "no";
        "valid users" = "@backup-users";
        "fruit:time machine" = "yes";
      };
    };
  };

  systemd.services.samba-smbd.serviceConfig.BindReadOnlyPaths = [
    "${sambaModulesWithSss}:${pkgs.samba}/lib/samba"
  ];
  systemd.services.samba-winbindd.serviceConfig.BindReadOnlyPaths = [
    "${sambaModulesWithSss}:${pkgs.samba}/lib/samba"
  ];
}
```

Plus the one-time imperative steps, in order:

```bash
ipa host-add fileserver.ipa.example.com --ip-address=192.0.2.20
ipa-getkeytab -s ipa1.ipa.example.com -p host/fileserver.ipa.example.com -k /etc/krb5.keytab
ipa service-add cifs/fileserver.ipa.example.com
net setdomainsid S-1-5-21-1234567890-234567891-345678912
ipa-getkeytab -s ipa1.ipa.example.com -p cifs/fileserver.ipa.example.com \
  -k /var/lib/samba/samba.keytab -P
net changesecretpw -f -i < /run/secrets/cifs-machine-pw   # never the password on argv
```

## Error-message index

Because this post exists to be found:

| You saw | Go to |
| --- | --- |
| `Bad talloc magic value - wrong talloc version used/mixed` / `PANIC` in winbindd when loading `idmap_sss` | Step 2 — you're on `samba4Full`; use plain `pkgs.samba` |
| `session setup failed: NT_STATUS_BAD_TOKEN_TYPE` on a kerberized mount | Step 3 — NixOS defaulted you to `security = user`; set `security = domain` |
| `Error loading module ... Too many levels of symbolic links` (ELOOP) | Step 4 — your grafted module is a symlink; copy the `.so` for real |
| `Could not fetch our SID - did we join?` in winbindd logs | Step 5 — run `net setdomainsid` with the IPA domain SID |
| `wbinfo --sid-to-uid` fails even though the config is now correct | Step 5 — stale negative idmap cache; `net cache flush` |
| `session setup failed: NT_STATUS_NTLM_BLOCKED` | Step 6 — working as intended; get a ticket (`kinit`) instead |
| macOS prompts for a password on a Kerberos share | Step 7 — mount by the exact `cifs/` SPN FQDN, never IP/shortname/`.local` |

None of this required patching samba, forking sssd, or running `ipa-adtrust-install` against the realm. A stock NixOS module set, one `runCommand` derivation, one bind mount, and three imperative commands that a real `ipa-client-samba` port could eventually absorb. If you build that port, or if any of the failure modes above manifest differently on your samba version, I'd like to hear about it.
