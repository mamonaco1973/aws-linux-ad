#!/bin/bash
# ==============================================================================
# validate.sh - Linux + Active Directory (3-way) Quick Start Validation
# ------------------------------------------------------------------------------
# Purpose:
#   - Looks up the lab instances by Name tag and prints the browser-terminal
#     (shellinabox, http://<host>) and RDP endpoints for fast access.
#
# Instances:
#   - linux-sssd-ad    (SSSD, AD provider)
#   - linux-winbind    (Winbind only)
#   - linux-sssd-ldap  (SSSD, LDAP provider)
#   - windows-ad-admin (RSAT / ADUC admin host)
#
# Requirements:
#   - AWS CLI installed and authenticated; instances tagged as above.
# ==============================================================================

set -euo pipefail

export AWS_DEFAULT_REGION="us-east-1"

# ------------------------------------------------------------------------------
# Helper: public DNS for a Name tag (running instances only)
# ------------------------------------------------------------------------------
get_public_dns_by_name_tag() {
  local name_tag="$1"
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${name_tag}" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].PublicDnsName" \
    --output text | xargs
}

echo ""
echo "============================================================================"
echo "Linux + Active Directory - Three-Way Quick Start"
echo "============================================================================"
echo ""
echo "Log in at each browser terminal as a domain user (e.g. jsmith / rpatel)"
echo "using the password from Secrets Manager, then compare:"
echo "  id <user> ; getent passwd <user> ; getent group linux-admins"
echo ""

for pair in \
  "linux-sssd-ad:SSSD (AD provider)" \
  "linux-winbind:Winbind only" \
  "linux-sssd-ldap:SSSD (LDAP provider)"; do
  tag="${pair%%:*}"; label="${pair#*:}"
  dns="$(get_public_dns_by_name_tag "$tag")"
  if [ -n "$dns" ] && [ "$dns" != "None" ]; then
    printf "NOTE: %-22s -> http://%s\n" "$label" "$dns"
  else
    printf "WARN: %-22s (%s) not found / no public DNS\n" "$label" "$tag"
  fi
done

echo ""
win_dns="$(get_public_dns_by_name_tag "windows-ad-admin")"
if [ -n "$win_dns" ] && [ "$win_dns" != "None" ]; then
  echo "NOTE: Windows ADUC host (RDP)   -> ${win_dns}"
else
  echo "WARN: windows-ad-admin not found or has no public DNS"
fi

echo ""
echo "NOTE: Validation complete."
echo ""
