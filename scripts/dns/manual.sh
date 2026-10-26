#!/bin/bash
# DNS provider: manual - works with any DNS host. Current records are read through DNS (authoritative
# servers), the records to publish are written to a zone snippet to paste in the provider's panel.
# shellcheck disable=SC2154  # DNS_DOMAIN is set by 04-dns-publish.sh

# Authoritative server of the zone holding DNS_DOMAIN. A subdomain (mail.client.org) usually has no NS of its
# own: walk up to the parent zone. Without any NS (domain not delegated yet), fall back to a public resolver.
_man_ns() {
  if [ -z "${MAN_NS:-}" ]; then
    local d=$DNS_DOMAIN
    while [ -z "${MAN_NS:-}" ]; do
      MAN_NS=$(dig +short NS "$d" 2>/dev/null | head -1)
      [[ "$d" == *.*.* ]] || break   # never above the registrable domain (client.org)
      d=${d#*.}
    done
    MAN_NS=${MAN_NS:-1.1.1.1}
  fi
  echo "$MAN_NS"
}
_man_fqdn() { [ "$1" = @ ] && echo "$DNS_DOMAIN" || echo "$1.$DNS_DOMAIN"; }

dns_check_config() {
  [ "$(_man_ns)" != 1.1.1.1 ] || warn "no authoritative server found for $DNS_DOMAIN: current records are read through 1.1.1.1"
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
