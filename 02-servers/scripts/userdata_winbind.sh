#!/bin/bash
# ==============================================================================
# userdata_winbind.sh  —  identity method: Winbind only (no SSSD)
#
# realmd joins with winbind as the client. Winbind is the identity/auth stack;
# it reads POSIX uidNumber/gidNumber from AD (idmap backend = ad). Includes the
# four non-obvious knobs required for winbind-only to fully work:
#   - idmap stanza keyed on the NetBIOS name, not the realm
#   - unix_primary_group = yes  (primary GID from the user's gidNumber, since
#     "Domain Users" has no gidNumber)
#   - winbind expand groups = 1 (so getent group lists members)
#   - do NOT override "netbios name" (would break the machine trust)
# ==============================================================================
set -euo pipefail
exec > >(tee -a /root/userdata.log | logger -t user-data -s 2>/dev/console) 2>&1
trap 'echo "ERROR at line $LINENO"; exit 1' ERR
echo "winbind user-data start ($(date -Is))"

export DEBIAN_FRONTEND=noninteractive
export AWS_DEFAULT_REGION=us-east-1

# ------------------------------------------------------------------------------
# Packages — winbind/samba (no sssd) + shellinabox
# ------------------------------------------------------------------------------
apt-get update -y
apt-get install -y \
  realmd adcli krb5-user samba samba-common-bin winbind libpam-winbind \
  libnss-winbind oddjob oddjob-mkhomedir packagekit jq shellinabox curl unzip

# AWS CLI v2 (the 'awscli' apt package was dropped in Ubuntu 24.04).
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q -o /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip
export PATH="$PATH:/usr/local/bin"

# ------------------------------------------------------------------------------
# Domain admin credential (join only)
# ------------------------------------------------------------------------------
secret=$(aws secretsmanager get-secret-value \
  --secret-id ${admin_secret} --query SecretString --output text)
admin_password=$(echo "$secret" | jq -r .password)
admin_user=$(echo "$secret" | jq -r .username | sed 's/.*\\//')

# ------------------------------------------------------------------------------
# Join with winbind as the client software
# ------------------------------------------------------------------------------
echo "$admin_password" | realm join \
  --client-software=winbind --membership-software=samba \
  -U "$admin_user" ${domain_fqdn} --verbose

pam-auth-update --enable winbind --enable mkhomedir

# ------------------------------------------------------------------------------
# Lay down our tuned smb.conf (login-only; no file shares)
# ------------------------------------------------------------------------------
systemctl stop winbind

cat > /etc/samba/smb.conf <<EOF
[global]
workgroup = ${netbios}
security = ads
realm = ${realm}

kerberos method = secrets and keytab

template homedir = /home/%U
template shell = /bin/bash

# POSIX UIDs read straight from AD (RFC2307). Keyed on the NetBIOS name, and
# unix_primary_group=yes so the primary GID comes from the user's own gidNumber
# rather than the (gidNumber-less) "Domain Users" primary group.
idmap config ${netbios} : backend = ad
idmap config ${netbios} : schema_mode = rfc2307
idmap config ${netbios} : unix_nss_info = no
idmap config ${netbios} : unix_primary_group = yes
idmap config ${netbios} : range = 10000-1999999999
idmap config * : backend = tdb
idmap config * : range = 1-9999

winbind use default domain = yes
winbind normalize names = yes
winbind refresh tickets = yes
winbind offline logon = yes
winbind enum groups = yes
winbind enum users = yes
# List group members in getent group (off by default in winbind).
winbind expand groups = 1
EOF

# ------------------------------------------------------------------------------
# nsswitch -> files + winbind (no sss)
# ------------------------------------------------------------------------------
cat > /etc/nsswitch.conf <<EOF
passwd:     files winbind
group:      files winbind
shadow:     files winbind
hosts:      files dns myhostname
services:   files
netgroup:   nis
EOF

systemctl restart winbind smbd nmbd

# ------------------------------------------------------------------------------
# shellinabox — browser login on :80 (HTTP, no TLS — lab only)
# ------------------------------------------------------------------------------
sed -i 's/^SHELLINABOX_PORT=.*/SHELLINABOX_PORT=80/' /etc/default/shellinabox
sed -i 's|^SHELLINABOX_ARGS=.*|SHELLINABOX_ARGS="--no-beep --disable-ssl"|' /etc/default/shellinabox
systemctl enable shellinabox
systemctl restart shellinabox

# ------------------------------------------------------------------------------
# Wait for winbind to resolve a domain user, then a non-fatal sanity pass.
# ------------------------------------------------------------------------------
for i in $(seq 1 30); do
  if wbinfo --ping-dc >/dev/null 2>&1 && getent passwd rpatel >/dev/null 2>&1; then break; fi
  echo "waiting for winbind ($i/30)..."; sleep 2
done
for u in jsmith rpatel akumar edavis; do
  if id "$u" >/dev/null 2>&1; then echo "OK resolve: $u ($(id -u "$u"))"; else echo "WARN unresolved: $u"; fi
done
echo "winbind user-data done ($(date -Is))"
