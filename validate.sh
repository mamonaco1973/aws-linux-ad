#!/bin/bash
# ==============================================================================
# validate.sh - Linux + Active Directory (3-way) Quick Start Validation
# ------------------------------------------------------------------------------
# Purpose:
#   - Looks up the lab instances by Name tag.
#   - WAITS until shellinabox (port 80) is actually listening on each of the
#     three Linux boxes (userdata takes a few minutes), then prints the browser
#     terminal URLs. Also prints the Windows RDP endpoint.
#
# Instances:
#   - linux-sssd-ad    (SSSD, AD provider)
#   - linux-winbind    (Winbind only)
#   - linux-sssd-ldap  (SSSD, LDAP provider)
#   - windows-ad-admin (RSAT / ADUC admin host)
#
# Requirements:
#   - AWS CLI + curl installed and authenticated; instances tagged as above.
# ==============================================================================

set -euo pipefail

export AWS_DEFAULT_REGION="us-east-1"

# Poll settings: how long to wait for :80 to come up (userdata install/join).
WAIT_TRIES=90      # attempts per host
WAIT_INTERVAL=5    # seconds between attempts (90 * 5s = 7.5 min max)

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

# ------------------------------------------------------------------------------
# Helper: wait until http://<host>/ answers (shellinabox on :80)
# ------------------------------------------------------------------------------
wait_http() {
  local host="$1" i
  for ((i = 1; i <= WAIT_TRIES; i++)); do
    if curl -s -o /dev/null --max-time 4 "http://${host}/"; then
      return 0
    fi
    printf "\r  waiting for :80 on %s  (%d/%d)   " "$host" "$i" "$WAIT_TRIES"
    sleep "$WAIT_INTERVAL"
  done
  return 1
}

echo ""
echo "============================================================================"
echo "Linux + Active Directory - Three-Way Quick Start"
echo "============================================================================"
echo ""
echo "Waiting for shellinabox (:80) to come up on each Linux client..."
echo ""

for pair in \
  "linux-sssd-ad:SSSD (AD provider)" \
  "linux-winbind:Winbind only" \
  "linux-sssd-ldap:SSSD (LDAP provider)"; do
  tag="${pair%%:*}"; label="${pair#*:}"
  dns="$(get_public_dns_by_name_tag "$tag")"
  if [ -z "$dns" ] || [ "$dns" = "None" ]; then
    printf "WARN: %-22s (%s) not found / no public DNS\n" "$label" "$tag"
    continue
  fi
  if wait_http "$dns"; then
    printf "\rNOTE: %-22s -> http://%s        \n" "$label" "$dns"
  else
    printf "\rWARN: %-22s -> :80 not up after %ds  (http://%s)\n" \
      "$label" "$((WAIT_TRIES * WAIT_INTERVAL))" "$dns"
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
echo "Log in at each browser terminal as a domain user (e.g. jsmith / rpatel),"
echo "then compare:  id <user> ; getent passwd <user> ; getent group linux-admins"
echo ""
echo "NOTE: Validation complete."
echo ""
