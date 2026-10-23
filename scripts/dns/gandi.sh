#!/bin/bash
# DNS provider: Gandi LiveDNS (https://api.gandi.net/docs/livedns/). Needs GANDI_PAT.
# shellcheck disable=SC2154  # DNS_DOMAIN is set by 04-dns-publish.sh

_gandi() { # METHOD PATH [JSON]
  curl -s -m 30 -X "$1" -H "Authorization: Bearer $GANDI_PAT" -H "Content-Type: application/json" \
    "https://api.gandi.net/v5/livedns/domains/$DNS_DOMAIN/$2" ${3:+-d "$3"}
}
_gandi_name() { [ "$1" = @ ] && echo %40 || echo "$1"; }

dns_check_config() {
  [ -n "$GANDI_PAT" ] || die "GANDI_PAT is empty in config.env"
  _gandi GET records | jq -e 'type == "array"' >/dev/null || die "Gandi API: cannot read the zone of $DNS_DOMAIN"
}

dns_backup() { _gandi GET records > "$1"; }

dns_get() {
  _gandi GET "records/$(_gandi_name "$1")/$2" | jq -r '.rrset_values[]? // empty' |
    if [ "$2" = TXT ]; then txt_unquote; else cat; fi
}

dns_set() { # NAME TYPE TTL VALUE...
  local name=$1 type=$2 ttl=$3 v values=()
  shift 3
  for v in "$@"; do
    if [ "$type" = TXT ]; then values+=("$(txt_chunks "$v")"); else values+=("$(jq -n --arg v "$v" '$v')"); fi
  done
  local body r
  body=$(printf '%s\n' "${values[@]}" | jq -s --argjson t "$ttl" '{rrset_ttl: $t, rrset_values: .}')
  r=$(_gandi PUT "records/$(_gandi_name "$name")/$type" "$body")
  jq -e '.message // "" | test("(?i)created|updated")' <<< "$r" >/dev/null || { fail "$name $type: $r"; return 1; }
}

# LiveDNS sometimes answers "updated" but keeps serving the previous TXT value:
# publishing the same values with another TTL forces the update.
dns_republish() {
  local values=()
  mapfile -t values < <(dns_get "$1" "$2")
  [ ${#values[@]} -gt 0 ] && dns_set "$1" "$2" "$((DNS_TTL + 1))" "${values[@]}"
}
