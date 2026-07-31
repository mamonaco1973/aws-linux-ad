# Linux + Active Directory: SSSD-ad vs Winbind vs SSSD-ldap

A hands-on lab that joins **three Ubuntu machines to the same mini-Active-Directory
three different ways**, so you can compare the approaches side by side:

| Instance | Method | How it joins | ID mapping | Kerberos / computer object |
|---|---|---|---|---|
| `linux-sssd-ad`   | **SSSD, AD provider**   | `realm join` (Kerberos) | POSIX (`ldap_id_mapping = False`) | yes |
| `linux-winbind`   | **Winbind only**        | `realm join --client-software=winbind` | POSIX (`idmap backend = ad`) | yes |
| `linux-sssd-ldap` | **SSSD, LDAP provider** | **no join** — LDAPS + bind account | POSIX (`ldap_id_mapping = False`) | **no** |

All three read the **same POSIX `uidNumber`/`gidNumber` from AD**, so a user has
the same UID on every box. A small **Windows admin host** (RSAT / ADUC) is
included so you can watch the AD side per scenario — e.g. a computer object
appears for `sssd-ad` and `winbind`, but **not** for `sssd-ldap`.

Each Linux box runs **shellinabox on port 80**, so you test by browsing to
`http://<instance>` and logging in as a domain user — exactly like SSH, but it
exercises that box's PAM/identity stack.

## Architecture

```
                 mini-AD (Samba DC, "ad1")  ── serves DNS, Kerberos, LDAP/LDAPS,
                        │                        and /ca.pem (its public CA)
        ┌───────────────┼───────────────┬────────────────────┐
   linux-sssd-ad   linux-winbind   linux-sssd-ldap      windows-ad-admin
   (SSSD ad)       (winbind)       (SSSD ldap, LDAPS)   (RSAT / ADUC)
   shellinabox:80  shellinabox:80  shellinabox:80        RDP:3389
```

- **`01-directory/`** — VPC, subnets, NAT, and the `module-aws-mini-ad` Samba DC
  (users + POSIX attributes from `users.json`). DHCP points VPC DNS at the DC.
- **`02-servers/`** — the three Ubuntu clients (one per method) + the Windows
  admin host.

> The project points at a **local** copy of `module-aws-mini-ad` (`../../module-aws-mini-ad`)
> because it adds a `/ca.pem` route to the DC's Flask app so the SSSD-`ldap`
> client can fetch the Samba CA and trust `ldaps://`.

## The SSSD-`ldap` gotcha (why it needs a CA)

`ldap`-mode auth is a simple bind, so it **must** run over LDAPS, which means the
client has to trust the DC's TLS cert. A Samba DC auto-generates its own CA, so
the client just fetches `http://ad1.<domain>/ca.pem` at boot. Against **AWS
Managed AD** you'd instead deploy AD CS and distribute that root — the "you need
a CA" cost is a Samba-lab shortcut here.

## Deploy

```bash
./check_env.sh        # verify aws / terraform / jq
./apply.sh            # phase 1: 01-directory (mini-AD), phase 2: 02-servers
./validate.sh         # prints the browser-terminal + RDP URLs
```

## Test / compare

Browse to each `http://<linux-box>` and log in as `jsmith` / `rpatel` (password
in Secrets Manager), then run the same commands on all three and compare:

```bash
id jsmith
getent passwd jsmith
getent group linux-admins
getent group mcloud-users
```

On the Windows host (RDP), open **Active Directory Users and Computers** to see
what each method did to the directory (computer objects, group membership,
POSIX attributes).

## Teardown

```bash
./destroy.sh          # tears down both phases and cleans up the demo secrets
```

## Notes

- **Lab only.** shellinabox is HTTP (no TLS) on port 80, security groups are open
  to `0.0.0.0/0`, and the SSSD-`ldap` box reuses the domain admin as its bind
  account (its password lands in `sssd.conf`). None of this is production-safe.
- Users, groups, and POSIX IDs are defined in
  `01-directory/scripts/users.json.template`.
