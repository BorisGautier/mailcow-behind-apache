#!/bin/bash
# DNS provider: Cloudflare (https://developers.cloudflare.com/api/resources/dns/).
# Needs CLOUDFLARE_API_TOKEN with Zone:Read and DNS:Edit. Records are created "DNS only" (not proxied):
# mail traffic cannot go through Cloudflare's proxy.
# shellcheck disable=SC2154  # DNS_DOMAIN is set by 04-dns-publish.sh

_cf() { # METHOD PATH [JSON]
  curl -s -m 30 -X "$1" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/$2" ${3:+-d "$3"}
}
_cf_fqdn() { [ "$1" = @ ] && echo "$DNS_DOMAIN" || echo "$1.$DNS_DOMAIN"; }

dns_check_config() {
  [ -n "$CLOUDFLARE_API_TOKEN" ] || die "CLOUDFLARE_API_TOKEN is empty in config.env"
  CF_ZONE_ID=$(_cf GET "zones?name=$DNS_DOMAIN" | jq -r '.result[0].id // empty')
  [ -n "$CF_ZONE_ID" ] || die "Cloudflare: zone $DNS_DOMAIN not found (or the token cannot read it)"
}

dns_backup() { _cf GET "zones/$CF_ZONE_ID/dns_records?per_page=5000" | jq '.result' > "$1"; }

_cf_records() { _cf GET "zones/$CF_ZONE_ID/dns_records?type=$2&name=$(_cf_fqdn "$1")&per_page=100" | jq -c '.result[]?'; }

# Current records as "ID<TAB>VALUE" (VALUE in zone-file syntax, TXT unquoted)
_cf_values() {
  _cf_records "$1" "$2" | jq -r '[.id,
    (if .type == "MX" then "\(.priority) \(.content)."
     elif .type == "SRV" then "\(.data.priority) \(.data.weight) \(.data.port) \(.data.target)."
     elif .type == "CNAME" then "\(.content)."
     else .content end)] | @tsv' | sed -e 's/\t"/\t/' -e 's/" "//g' -e 's/"$//'
}

dns_get() { _cf_values "$1" "$2" | cut -f2-; }

# Cloudflare record payload for one value (zone-file syntax, see engine.sh). Args: FQDN TYPE TTL VALUE
cf_record_json() {
  local fqdn=$1 type=$2 ttl=$3 v=$4 p w port target
  case "$type" in
    MX)  read -r p target <<< "$v"
         jq -nc --arg n "$fqdn" --arg c "${target%.}" --argjson p "$p" --argjson t "$ttl" \
           '{type: "MX", name: $n, content: $c, priority: $p, ttl: $t}' ;;
    SRV) read -r p w port target <<< "$v"
         jq -nc --arg n "$fqdn" --arg tg "${target%.}" --argjson p "$p" --argjson w "$w" --argjson po "$port" --argjson t "$ttl" \
           '{type: "SRV", name: $n, data: {priority: $p, weight: $w, port: $po, target: $tg}, ttl: $t}' ;;
    CNAME) jq -nc --arg n "$fqdn" --arg c "${v%.}" --argjson t "$ttl" \
           '{type: "CNAME", name: $n, content: $c, ttl: $t, proxied: false}' ;;
    TXT) local c=$v; [ ${#v} -gt 255 ] && c=$(txt_chunks "$v" | jq -r .)
         jq -nc --arg n "$fqdn" --arg c "$c" --argjson t "$ttl" '{type: "TXT", name: $n, content: $c, ttl: $t}' ;;
    *)   jq -nc --arg ty "$type" --arg n "$fqdn" --arg c "$v" --argjson t "$ttl" '{type: $ty, name: $n, content: $c, ttl: $t}' ;;
  esac
}

dns_set() { # NAME TYPE TTL VALUE...
  local name=$1 type=$2 ttl=$3 id v r old keep=()
  shift 3
  old=$(_cf_values "$name" "$type")
  # identical records are kept, missing ones created first, the others removed last
  # (Cloudflare refuses duplicates, and the name is never left without a record)
  for v in "$@"; do
    id=$(awk -F'\t' -v v="$v" '$2 == v { print $1; exit }' <<< "$old")
    if [ -n "$id" ]; then keep+=("$id"); continue; fi
    r=$(_cf POST "zones/$CF_ZONE_ID/dns_records" "$(cf_record_json "$(_cf_fqdn "$name")" "$type" "$ttl" "$v")")
    jq -e '.success' <<< "$r" >/dev/null || { fail "$name $type: $(jq -c '.errors' <<< "$r")"; return 1; }
  done
  local -a ids
  mapfile -t ids < <(cut -f1 <<< "$old")
  for id in "${ids[@]}"; do
    [ -n "$id" ] || continue
    [[ " ${keep[*]} " == *" $id "* ]] || _cf DELETE "zones/$CF_ZONE_ID/dns_records/$id" >/dev/null
  done
}
