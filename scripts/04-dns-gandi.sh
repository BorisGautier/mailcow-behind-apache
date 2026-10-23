#!/bin/bash
# Publishes the mail DNS records of a domain on Gandi LiveDNS. Backs up the zone first.
# The other TXT values at the apex (site verifications...) are kept; any old SPF is replaced.
# Publie les enregistrements DNS mail d'un domaine chez Gandi LiveDNS, apres sauvegarde de la zone.
#
# Usage: sudo ./scripts/04-dns-gandi.sh example.org [--yes]
#   --yes : do not ask before replacing an existing MX (switching MX moves the domain's mail here)
. "$(dirname "$0")/lib.sh"
require_root
load_config

domain=${1:-}; [ -n "$domain" ] || die "usage: $0 <domain> [--yes]"
assume_yes=no; [ "${2:-}" = --yes ] && assume_yes=yes
[ -n "$GANDI_PAT" ] || die "GANDI_PAT is empty in config.env"
API=https://api.gandi.net/v5/livedns/domains

gandi() { # method path [json]
  curl -s -m 30 -X "$1" -H "Authorization: Bearer $GANDI_PAT" -H "Content-Type: application/json" \
    "$API/$domain/$2" ${3:+-d "$3"}
}

info "Zone backup"
zone=$(gandi GET records)
echo "$zone" | jq -e 'type == "array"' >/dev/null || die "Gandi API error: $zone"
mkdir -p /root/dns-backups && chmod 700 /root/dns-backups
backup=/root/dns-backups/$domain-$(date +%F-%H%M%S).json
echo "$zone" > "$backup"; ok "$backup"

dkim=$(mailcow_api GET "get/dkim/$domain" | jq -r '.dkim_txt // empty')
[ -n "$dkim" ] || die "no DKIM key for $domain in mailcow: run 03-add-domain.sh first"

current_mx=$(echo "$zone" | jq -r '.[] | select(.rrset_name=="@" and .rrset_type=="MX") | .rrset_values[]')
if [ -n "$current_mx" ] && ! echo "$current_mx" | grep -q " $MAIL_HOSTNAME\.$"; then
  warn "current MX of $domain: $(echo "$current_mx" | tr '\n' ' ')"
  warn "replacing it sends ALL new mail for $domain to this server. Create the mailboxes first,"
  warn "and copy existing mail with imapsync (see docs/en/migration.md)."
  if [ "$assume_yes" != yes ]; then
    read -r -p "Replace the MX now? [y/N] " a; [[ "$a" =~ ^[yYoO] ]] || die "aborted, nothing changed"
  fi
fi

put() { # name type ttl values-json-array
  local r; r=$(gandi PUT "records/$1/$2" "$(jq -nc --argjson t "$3" --argjson v "$4" '{rrset_ttl:$t, rrset_values:$v}')")
  if echo "$r" | jq -e '.message // "" | test("created|updated|Created|Updated|DNS Record")' >/dev/null 2>&1 || [ -z "$r" ]; then ok "$1 $2"
  else fail "$1 $2: $r"; fi
}
q() { jq -nc --arg s "$1" '$s | "\"" + . + "\""'; }   # quote a TXT string

# Apex TXT: keep everything that is not SPF, then add our SPF
spf="v=spf1 mx a:$MAIL_HOSTNAME${SPF_EXTRA:+ $SPF_EXTRA} ~all"
old_spf=$(echo "$zone" | jq -r '.[] | select(.rrset_name=="@" and .rrset_type=="TXT") | .rrset_values[] | select(test("v=spf1"))' | head -1)
[ -n "$old_spf" ] && [ "$old_spf" != "\"$spf\"" ] && warn "replacing SPF $old_spf (add the mechanisms you still need to SPF_EXTRA)"
apex_txt=$(echo "$zone" | jq -c --arg spf "\"$spf\"" \
  '[.[] | select(.rrset_name=="@" and .rrset_type=="TXT") | .rrset_values[] | select(test("v=spf1") | not)] + [$spf]')

# DKIM: TXT strings are limited to 255 characters -> split in 250-character chunks
dkim_value=$(echo -n "$dkim" | fold -w 250 | jq -Rn '[inputs | "\"" + . + "\""] | join(" ")')

rua=${DMARC_RUA//\{domain\}/$domain}
info "Publishing records"
put @ MX 1800 "[\"10 $MAIL_HOSTNAME.\"]"
put @ TXT 1800 "$apex_txt"
put dkim._domainkey TXT 1800 "[$dkim_value]"
put _dmarc TXT 1800 "[$(q "v=DMARC1; p=$DMARC_POLICY; rua=mailto:$rua")]"
put _autodiscover._tcp SRV 10800 "[\"0 1 443 $MAIL_HOSTNAME.\"]"
put _submissions._tcp SRV 10800 "[\"0 1 465 $MAIL_HOSTNAME.\"]"
put _submission._tcp SRV 10800 "[\"0 1 587 $MAIL_HOSTNAME.\"]"
put _imaps._tcp SRV 10800 "[\"0 1 993 $MAIL_HOSTNAME.\"]"
put _pop3s._tcp SRV 10800 "[\"10 1 995 $MAIL_HOSTNAME.\"]"
put webmail CNAME 10800 "[\"$MAIL_HOSTNAME.\"]"

info "Checking on Gandi's authoritative servers"
ns=$(dig +short NS "$domain" | head -1)
check_txt() { dig +short TXT "$1" @"$ns" | tr -d '"' | tr -d ' ' | grep -q "$2"; }
for attempt in 1 2; do
  sleep 20
  missing=()
  check_txt "$domain" "v=spf1mxa:$MAIL_HOSTNAME" || missing+=(SPF)
  check_txt "dkim._domainkey.$domain" "v=DKIM1" || missing+=(DKIM)
  check_txt "_dmarc.$domain" "v=DMARC1" || missing+=(DMARC)
  [ ${#missing[@]} -eq 0 ] && break
  if [ "$attempt" = 1 ]; then
    # LiveDNS sometimes accepts a TXT update without republishing it; a PUT with another TTL forces it
    warn "not visible yet on $ns: ${missing[*]} - re-publishing with a different TTL"
    put @ TXT 1801 "$apex_txt"; put dkim._domainkey TXT 1801 "[$dkim_value]"
    put _dmarc TXT 1801 "[$(q "v=DMARC1; p=$DMARC_POLICY; rua=mailto:$rua")]"
  fi
done
if [ ${#missing[@]} -eq 0 ]; then ok "SPF, DKIM and DMARC visible on $ns"
else fail "still missing on $ns: ${missing[*]} (check in the Gandi panel)"; fi
mx=$(dig +short MX "$domain" @"$ns" || true)
echo "$mx" | grep -q "$MAIL_HOSTNAME" && ok "MX: $mx" || fail "MX on $ns: ${mx:-none}"
echo
echo "Resolvers may keep the old values for up to the previous TTL. Restore: $backup"
