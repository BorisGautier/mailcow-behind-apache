#!/bin/bash
# DNS provider: manual - works with any DNS host. Current records are read through DNS (authoritative
# servers), the records to publish are written to a zone snippet to paste in the provider's panel.
# shellcheck disable=SC2154  # DNS_DOMAIN is set by 04-dns-publish.sh

_man_ns() { [ -n "${MAN_NS:-}" ] || MAN_NS=$(dig +short NS "$DNS_DOMAIN" | head -1); echo "$MAN_NS"; }
_man_fqdn() { [ "$1" = @ ] && echo "$DNS_DOMAIN" || echo "$1.$DNS_DOMAIN"; }

dns_check_config() {
  [ -n "$(_man_ns)" ] || warn "$DNS_DOMAIN has no NS record yet: current records cannot be read"
  DNS_ZONE_OUT="${DNS_BACKUP_DIR:-/root/dns-backups}/$DNS_DOMAIN-mail-records-$(date +%F-%H%M%S).zone"
  mkdir -p "$(dirname "$DNS_ZONE_OUT")"
  # shellcheck disable=SC2016  # $ORIGIN is a zone-file directive, not a shell variable
  printf '; Mail records for %s - paste them in your DNS provider (replace the existing ones of the same name/type)\n$ORIGIN %s.\n' \
    "$DNS_DOMAIN" "$DNS_DOMAIN" > "$DNS_ZONE_OUT"
}

dns_backup() { # what we may change, as served today
  local n t
  for n in @ dkim._domainkey _dmarc _autodiscover._tcp _submissions._tcp _submission._tcp _imaps._tcp _pop3s._tcp webmail; do
    for t in MX TXT SRV CNAME; do
      dig +noall +answer "$t" "$(_man_fqdn "$n")" @"$(_man_ns)" 2>/dev/null
    done
  done | sort -u | jq -Rs 'split("\n") | map(select(length > 0))' > "$1"
}

dns_get() {
  [ -n "$(_man_ns)" ] || return 0
  dig +short "$2" "$(_man_fqdn "$1")" @"$(_man_ns)" 2>/dev/null | if [ "$2" = TXT ]; then txt_unquote; else cat; fi
}

dns_set() { # NAME TYPE TTL VALUE... -> zone file lines
  local name=$1 type=$2 ttl=$3 v
  shift 3
  for v in "$@"; do
    if [ "$type" = TXT ]; then v=$(txt_chunks "$v" | jq -r .); fi
    printf '%-24s %s IN %-5s %s\n' "$name" "$ttl" "$type" "$v" >> "$DNS_ZONE_OUT"
  done
}
