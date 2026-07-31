#!/bin/bash
# ==============================================================================
# userdata_sssd_ad.sh  —  identity method: SSSD, AD provider
#
# The "simplest" path: realmd joins the domain (creating a computer object +
# keytab), SSSD becomes the identity/auth provider over Kerberos/GSSAPI. POSIX
# UIDs come from AD (ldap_id_mapping = False) so they match the other two boxes.
# ==============================================================================
set -euo pipefail
exec > >(tee -a /root/userdata.log | logger -t user-data -s 2>/dev/console) 2>&1
trap 'echo "ERROR at line $LINENO"; exit 1' ERR
echo "sssd-ad user-data start ($(date -Is))"

export DEBIAN_FRONTEND=noninteractive
export AWS_DEFAULT_REGION=us-east-1

# ------------------------------------------------------------------------------
# Packages — realmd/SSSD/AD provider + shellinabox web terminal
# ------------------------------------------------------------------------------
apt-get update -y
apt-get install -y \
  realmd sssd sssd-tools sssd-ad adcli krb5-user samba-common-bin \
  oddjob oddjob-mkhomedir packagekit awscli jq shellinabox

# ------------------------------------------------------------------------------
# Domain admin credential (used only to perform the join)
# ------------------------------------------------------------------------------
secret=$(aws secretsmanager get-secret-value \
  --secret-id ${admin_secret} --query SecretString --output text)
admin_password=$(echo "$secret" | jq -r .password)
admin_user=$(echo "$secret" | jq -r .username | sed 's/.*\\//')

# ------------------------------------------------------------------------------
# Join with SSSD (realmd's default client software)
# ------------------------------------------------------------------------------
echo "$admin_password" | realm join -U "$admin_user" ${domain_fqdn} --verbose

# ------------------------------------------------------------------------------
# SSSD tweaks:
#   - short login names (jsmith, not jsmith@domain)
#   - POSIX mapping: read uidNumber/gidNumber from AD (matches the other hosts)
#   - home under /home/%u
# ------------------------------------------------------------------------------
sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
sed -i 's/ldap_id_mapping = True/ldap_id_mapping = False/'                     /etc/sssd/sssd.conf
sed -i 's|fallback_homedir = /home/%u@%d|fallback_homedir = /home/%u|'         /etc/sssd/sssd.conf

pam-auth-update --enable mkhomedir
systemctl restart sssd

# ------------------------------------------------------------------------------
# shellinabox — browser login on :80 (HTTP, no TLS — lab only)
# ------------------------------------------------------------------------------
sed -i 's/^SHELLINABOX_PORT=.*/SHELLINABOX_PORT=80/' /etc/default/shellinabox
sed -i 's|^SHELLINABOX_ARGS=.*|SHELLINABOX_ARGS="--no-beep --disable-ssl"|' /etc/default/shellinabox
systemctl enable shellinabox
systemctl restart shellinabox

# ------------------------------------------------------------------------------
# Sanity: resolve/log in as the demo users (also triggers mkhomedir). Non-fatal.
# ------------------------------------------------------------------------------
for u in jsmith rpatel akumar edavis; do
  if id "$u" >/dev/null 2>&1; then echo "OK resolve: $u ($(id -u "$u"))"; else echo "WARN unresolved: $u"; fi
done
echo "sssd-ad user-data done ($(date -Is))"
