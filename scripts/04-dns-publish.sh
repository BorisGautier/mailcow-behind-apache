#!/bin/bash
# Publishes the mail DNS records of a domain (MX, SPF merged with the other TXT, DKIM, DMARC, SRV,
# webmail CNAME) at its DNS host, after a backup, then checks them on the authoritative servers.
# Publie les enregistrements DNS mail d'un domaine chez son hebergeur DNS, apres sauvegarde.
#
# Usage: sudo ./scripts/04-dns-publish.sh example.org [--provider NAME] [--spf-extra "include:..."] [--yes]
#   --provider  : gandi, cloudflare, lexicon or manual; overrides DNS_PROVIDER (domains on several DNS hosts)
#   --spf-extra : SPF mechanisms to keep for this domain (third-party senders); overrides SPF_EXTRA
#   --yes       : do not ask before replacing an existing MX or dropping SPF senders
. "$(dirname "$0")/lib.sh"
require_root
load_config

DNS_DOMAIN=${1:-}; [ -n "$DNS_DOMAIN" ] || die "usage: $0 <domain> [--provider NAME] [--spf-extra MECHANISMS] [--yes]"
shift
assume_yes=no
while [ $# -gt 0 ]; do
  case $1 in
    --provider) DNS_PROVIDER=$2; shift 2 ;;
    --spf-extra) SPF_EXTRA=$2; shift 2 ;;
    --yes) assume_yes=yes; shift ;;
    *) die "unknown option $1" ;;
  esac
done
provider_file="$REPO_DIR/scripts/dns/$DNS_PROVIDER.sh"
if [ ! -f "$provider_file" ]; then
  available=$(for f in "$REPO_DIR"/scripts/dns/*.sh; do b=$(basename "$f" .sh); [ "$b" = engine ] || printf '%s ' "$b"; done)
  die "unknown DNS provider '$DNS_PROVIDER' (available: $available)"
fi
# shellcheck source=dns/engine.sh
. "$REPO_DIR/scripts/dns/engine.sh"
# shellcheck disable=SC1090
. "$provider_file"

dkim=$(mailcow_api GET "get/dkim/$DNS_DOMAIN" | jq -r '.dkim_txt // empty')
[ -n "$dkim" ] || die "no DKIM key for $DNS_DOMAIN in mailcow: run 03-add-domain.sh $DNS_DOMAIN first"

dns_publish "$dkim" "$assume_yes"

if [ "$DNS_PROVIDER" = manual ]; then
  echo
  echo "${c_bold}Records to publish at the DNS host of $DNS_DOMAIN${c_reset} (also in $DNS_ZONE_OUT):"
  echo
  sed 's/^/  /' "$DNS_ZONE_OUT"
  echo
  echo "Replace the existing records of the same name and type (one SPF only: the @ TXT set above already"
  echo "contains the other TXT values of the apex). Then check with: sudo ./scripts/check.sh"
  exit 0
fi

sleep 10
dns_verify || true
echo
echo "Resolvers may keep the old values for up to the previous TTL. Restore: $DNS_LAST_BACKUP"
