#!/bin/bash
# DNS provider: dns-lexicon (https://github.com/dns-lexicon/dns-lexicon), one CLI for 100+ DNS hosts
# (OVH, Route 53, GoDaddy, Namecheap, Infomaniak, DigitalOcean, Hetzner, Scaleway, ...).
# Install: pipx install dns-lexicon   (or: pip install dns-lexicon)
# Config: LEXICON_PROVIDER=<name> and the provider's credentials as LEXICON_<PROVIDER>_<OPTION> in config.env.
# Providers differ in details (MX priority, long TXT): always finish with scripts/check.sh.
# shellcheck disable=SC2154  # DNS_DOMAIN is set by 04-dns-publish.sh

_lx() { lexicon "$LEXICON_PROVIDER" "$@"; }
_lx_fqdn() { [ "$1" = @ ] && echo "$DNS_DOMAIN" || echo "$1.$DNS_DOMAIN"; }

dns_check_config() {
  command -v lexicon >/dev/null || die "lexicon not found: pipx install dns-lexicon"
  [ -n "$LEXICON_PROVIDER" ] || die "LEXICON_PROVIDER is empty in config.env"
  _lx list "$DNS_DOMAIN" MX --output JSON >/dev/null 2>&1 \
    || die "lexicon $LEXICON_PROVIDER cannot read $DNS_DOMAIN: check the LEXICON_${LEXICON_PROVIDER^^}_* credentials"
}

dns_backup() {
  local t
  for t in A AAAA CNAME MX TXT SRV CAA NS; do _lx list "$DNS_DOMAIN" "$t" --output JSON 2>/dev/null || echo '[]'; done \
    | jq -s 'add' > "$1"
}

# "ID<TAB>VALUE"; MX/SRV/CNAME targets are given with the final dot, like the other providers
_lx_values() {
  _lx list "$DNS_DOMAIN" "$2" --name "$(_lx_fqdn "$1")" --output JSON 2>/dev/null | jq -r --arg t "$2" '
    .[]? | [.id, (if ($t == "MX" or $t == "SRV" or $t == "CNAME") and (.content | endswith(".") | not)
                   then .content + "." else .content end)] | @tsv' | sed -e 's/\t"/\t/' -e 's/" "//g' -e 's/"$//'
}

dns_get() { _lx_values "$1" "$2" | cut -f2-; }

dns_set() { # NAME TYPE TTL VALUE...
  local name=$1 type=$2 ttl=$3 v id old keep=()
  shift 3
  old=$(_lx_values "$name" "$type")
  for v in "$@"; do
    id=$(awk -F'\t' -v v="$v" '$2 == v { print $1; exit }' <<< "$old")
    if [ -n "$id" ]; then keep+=("$id"); continue; fi
    _lx create "$DNS_DOMAIN" "$type" --name "$(_lx_fqdn "$name")" --content "$v" --ttl "$ttl" >/dev/null \
      || { fail "$name $type: lexicon create failed"; return 1; }
  done
  local -a ids
  mapfile -t ids < <(cut -f1 <<< "$old")
  for id in "${ids[@]}"; do
    [ -n "$id" ] || continue
    [[ " ${keep[*]} " == *" $id "* ]] || _lx delete "$DNS_DOMAIN" "$type" --identifier "$id" >/dev/null
  done
}
