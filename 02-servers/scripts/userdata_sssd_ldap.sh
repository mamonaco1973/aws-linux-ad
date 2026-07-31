#!/bin/bash
# ==============================================================================
# userdata_sssd_ldap.sh  —  identity method: SSSD, LDAP provider
#
# The odd one out: NO domain join, NO computer object, NO Kerberos. SSSD talks
# to the DC as a plain LDAP directory over LDAPS, authenticating lookups with a
# bind (service) account. Requires trusting the DC's LDAPS cert — we fetch the
# Samba CA from the DC's /ca.pem endpoint. POSIX UIDs come from AD attributes
# (ldap_id_mapping = False), matching the other two boxes.
#
# NOTE: this is the experimental one — expect to iterate on cert SAN match,
# schema/attribute mappings, and bind DN.
# ==============================================================================
set -euo pipefail
exec > >(tee -a /root/userdata.log | logger -t user-data -s 2>/dev/console) 2>&1
trap 'echo "ERROR at line $LINENO"; exit 1' ERR
echo "sssd-ldap user-data start ($(date -Is))"

export DEBIAN_FRONTEND=noninteractive
export AWS_DEFAULT_REGION=us-east-1

# ------------------------------------------------------------------------------
# Packages — SSSD (no realmd/join) + LDAP tooling + shellinabox
# ------------------------------------------------------------------------------
apt-get update -y
apt-get install -y \
  sssd sssd-tools libsss-sudo libnss-sss libpam-sss ldap-utils \
  oddjob oddjob-mkhomedir ca-certificates curl awscli jq shellinabox

# ------------------------------------------------------------------------------
# Bind-account password (reuse the domain admin for this lab). It is written
# into sssd.conf below, so sssd.conf must be mode 600.
# ------------------------------------------------------------------------------
secret=$(aws secretsmanager get-secret-value \
  --secret-id ${admin_secret} --query SecretString --output text)
admin_password=$(echo "$secret" | jq -r .password)

# ------------------------------------------------------------------------------
# Fetch the DC's public CA cert so we can trust ldaps:// (Samba's auto-CA,
# served by the mini-ad Flask app on port 80). Retry until the DC is up.
# ------------------------------------------------------------------------------
for i in $(seq 1 40); do
  if curl -fsS "http://${dc_fqdn}/ca.pem" -o /etc/sssd/mini-ad-ca.pem; then
    echo "fetched CA from ${dc_fqdn}"; break
  fi
  echo "waiting for DC /ca.pem ($i/40)..."; sleep 5
done
chmod 644 /etc/sssd/mini-ad-ca.pem

# ------------------------------------------------------------------------------
# SSSD in LDAP-provider mode. ldap_schema=ad gives AD attribute defaults;
# ldap_id_mapping=False reads POSIX uidNumber/gidNumber (users have them, and
# SSSD takes the primary group from the user's own gidNumber — no Domain Users
# gidNumber needed, unlike winbind). override_homedir/default_shell because AD
# has no loginShell/unixHomeDirectory populated.
# ------------------------------------------------------------------------------
cat > /etc/sssd/sssd.conf <<EOF
[sssd]
services = nss, pam
config_file_version = 2
domains = ${domain_fqdn}

[domain/${domain_fqdn}]
id_provider = ldap
auth_provider = ldap
ldap_uri = ldaps://${dc_fqdn}
ldap_search_base = ${base_dn}
ldap_schema = ad
ldap_id_mapping = False
ldap_referrals = false

ldap_default_bind_dn = ${bind_dn}
ldap_default_authtok = $admin_password

ldap_tls_cacert = /etc/sssd/mini-ad-ca.pem
ldap_tls_reqcert = demand

override_homedir = /home/%u
default_shell = /bin/bash
cache_credentials = True
EOF
chmod 600 /etc/sssd/sssd.conf

# ------------------------------------------------------------------------------
# Wire nss + pam to SSSD (no realmd did this for us).
# ------------------------------------------------------------------------------
cat > /etc/nsswitch.conf <<EOF
passwd:     files sss
group:      files sss
shadow:     files sss
hosts:      files dns myhostname
services:   files
netgroup:   nis
EOF
pam-auth-update --enable sss --enable mkhomedir

systemctl enable sssd
systemctl restart sssd

# ------------------------------------------------------------------------------
# shellinabox — browser login on :80 (HTTP, no TLS — lab only)
# ------------------------------------------------------------------------------
sed -i 's/^SHELLINABOX_PORT=.*/SHELLINABOX_PORT=80/' /etc/default/shellinabox
sed -i 's|^SHELLINABOX_ARGS=.*|SHELLINABOX_ARGS="--no-beep --disable-ssl"|' /etc/default/shellinabox
systemctl enable shellinabox
systemctl restart shellinabox

# ------------------------------------------------------------------------------
# Non-fatal sanity pass (expected to need iteration on first build).
# ------------------------------------------------------------------------------
sleep 5
for u in jsmith rpatel akumar edavis; do
  if id "$u" >/dev/null 2>&1; then echo "OK resolve: $u ($(id -u "$u"))"; else echo "WARN unresolved: $u"; fi
done
echo "sssd-ldap user-data done ($(date -Is))"
